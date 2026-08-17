#include "NucleusBlobModules.hpp"

#include "NucleusNetworkClients.hpp"

#include <react/http/IHttpClient.h>
#include <react/utils/Base64.h>
#include <ReactCommon/TurboModuleUtils.h>

#include <folly/io/IOBuf.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstdint>
#include <iomanip>
#include <limits>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace nucleus::react {
namespace {

using facebook::jsi::Array;
using facebook::jsi::JSError;
using facebook::jsi::Object;
using facebook::jsi::PropNameID;
using facebook::jsi::Runtime;
using facebook::jsi::String;
using facebook::jsi::Value;
using facebook::react::TurboModule;
using facebook::react::http::Body;
using facebook::react::http::Headers;
using facebook::react::http::IRequestToken;
using facebook::react::http::NetworkCallbacks;

constexpr std::size_t maximumBlobBytes = 64 * 1024 * 1024;
constexpr std::size_t maximumMultipartBytes = 64 * 1024 * 1024;

struct BlobDescriptor final {
  std::string id;
  std::size_t offset{0};
  std::size_t size{0};
  std::string type;
};

std::string valueString(Runtime &runtime, const Value &value,
                        const char *field) {
  if (!value.isString()) {
    throw JSError(runtime, std::string(field) + " must be a string");
  }
  return value.asString(runtime).utf8(runtime);
}

std::size_t valueSize(Runtime &runtime, const Value &value,
                      const char *field) {
  if (!value.isNumber()) {
    throw JSError(runtime, std::string(field) + " must be a number");
  }
  const auto number = value.asNumber();
  if (number < 0 || number > static_cast<double>(maximumBlobBytes) ||
      number != static_cast<double>(static_cast<std::size_t>(number))) {
    throw JSError(runtime, std::string(field) + " is outside the Blob limit");
  }
  return static_cast<std::size_t>(number);
}

BlobDescriptor descriptorFromObject(Runtime &runtime, const Object &object) {
  BlobDescriptor result;
  result.id = valueString(runtime, object.getProperty(runtime, "blobId"),
                          "blobId");
  result.offset = valueSize(runtime, object.getProperty(runtime, "offset"),
                            "offset");
  result.size = valueSize(runtime, object.getProperty(runtime, "size"),
                          "size");
  const auto type = object.getProperty(runtime, "type");
  if (type.isString()) result.type = type.asString(runtime).utf8(runtime);
  return result;
}

Object descriptorObject(Runtime &runtime, const BlobDescriptor &descriptor) {
  Object result(runtime);
  result.setProperty(runtime, "blobId",
                     String::createFromUtf8(runtime, descriptor.id));
  result.setProperty(runtime, "offset",
                     static_cast<double>(descriptor.offset));
  result.setProperty(runtime, "size", static_cast<double>(descriptor.size));
  if (!descriptor.type.empty()) {
    result.setProperty(runtime, "type",
                       String::createFromUtf8(runtime, descriptor.type));
  }
  return result;
}

std::string bytesAsString(const std::vector<std::uint8_t> &bytes) {
  return {reinterpret_cast<const char *>(bytes.data()), bytes.size()};
}

std::optional<std::vector<std::uint8_t>> decodeBase64(
    std::string_view input) {
  static constexpr std::string_view alphabet =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  if (input.size() % 4 != 0) return std::nullopt;
  std::vector<std::uint8_t> output;
  output.reserve((input.size() / 4) * 3);
  for (std::size_t index = 0; index < input.size(); index += 4) {
    std::uint32_t value = 0;
    int padding = 0;
    for (int digit = 0; digit < 4; ++digit) {
      const char character = input[index + digit];
      if (character == '=') {
        ++padding;
        value <<= 6;
      } else {
        if (padding != 0) return std::nullopt;
        const auto position = alphabet.find(character);
        if (position == std::string_view::npos) return std::nullopt;
        value = (value << 6) | static_cast<std::uint32_t>(position);
      }
    }
    if (padding > 2 || (padding != 0 && index + 4 != input.size())) {
      return std::nullopt;
    }
    output.push_back(static_cast<std::uint8_t>((value >> 16) & 0xff));
    if (padding < 2) {
      output.push_back(static_cast<std::uint8_t>((value >> 8) & 0xff));
    }
    if (padding == 0) output.push_back(static_cast<std::uint8_t>(value & 0xff));
  }
  return output;
}

std::string encodeBase64(const std::vector<std::uint8_t> &bytes) {
  return facebook::react::base64Encode(bytesAsString(bytes));
}

std::vector<std::uint8_t> iobufBytes(const folly::IOBuf &buffer) {
  std::vector<std::uint8_t> result;
  result.reserve(buffer.computeChainDataLength());
  for (const auto &range : buffer) {
    result.insert(result.end(), range.begin(), range.end());
  }
  return result;
}

bool containsBytes(const std::vector<std::uint8_t> &bytes,
                   std::string_view value) {
  return std::search(bytes.begin(), bytes.end(), value.begin(), value.end()) !=
         bytes.end();
}

void appendString(std::vector<std::uint8_t> &output, std::string_view value) {
  if (output.size() + value.size() > maximumMultipartBytes) {
    throw std::length_error("multipart request exceeded the 64 MiB limit");
  }
  output.insert(output.end(), value.begin(), value.end());
}

void appendBytes(std::vector<std::uint8_t> &output,
                 const std::vector<std::uint8_t> &value) {
  if (output.size() + value.size() > maximumMultipartBytes) {
    throw std::length_error("multipart request exceeded the 64 MiB limit");
  }
  output.insert(output.end(), value.begin(), value.end());
}

bool validHeaderName(std::string_view name) {
  if (name.empty()) return false;
  return std::all_of(name.begin(), name.end(), [](unsigned char character) {
    return std::isalnum(character) || character == '-' || character == '_';
  });
}

bool validHeaderValue(std::string_view value) {
  return value.find('\r') == std::string_view::npos &&
         value.find('\n') == std::string_view::npos;
}

} // namespace

class BlobStore final {
public:
  bool store(std::string id, std::vector<std::uint8_t> bytes,
             std::string &error) {
    if (bytes.size() > maximumBlobBytes) {
      error = "blob exceeded the 64 MiB per-runtime limit";
      return false;
    }
    std::lock_guard lock(mutex_);
    const auto previous = blobs_.find(id);
    const std::size_t previousSize =
        previous == blobs_.end() ? 0 : previous->second.size();
    if (totalBytes_ - previousSize + bytes.size() > maximumBlobBytes) {
      error = "blob store exceeded the 64 MiB per-runtime limit";
      return false;
    }
    totalBytes_ = totalBytes_ - previousSize + bytes.size();
    blobs_.insert_or_assign(std::move(id), std::move(bytes));
    return true;
  }

  std::optional<BlobDescriptor> storeGenerated(
      std::vector<std::uint8_t> bytes, std::string type, std::string &error) {
    const auto sequence = nextID_.fetch_add(1, std::memory_order_relaxed);
    std::ostringstream stream;
    stream << "nucleus-blob-" << std::hex << sequence;
    BlobDescriptor descriptor{stream.str(), 0, bytes.size(), std::move(type)};
    if (!store(descriptor.id, std::move(bytes), error)) return std::nullopt;
    return descriptor;
  }

  std::optional<std::vector<std::uint8_t>>
  resolve(const BlobDescriptor &descriptor) const {
    std::lock_guard lock(mutex_);
    const auto found = blobs_.find(descriptor.id);
    if (found == blobs_.end() || descriptor.offset > found->second.size() ||
        descriptor.size > found->second.size() - descriptor.offset) {
      return std::nullopt;
    }
    return std::vector<std::uint8_t>(
        found->second.begin() + static_cast<std::ptrdiff_t>(descriptor.offset),
        found->second.begin() + static_cast<std::ptrdiff_t>(descriptor.offset +
                                                            descriptor.size));
  }

  std::optional<std::vector<std::uint8_t>> resolveURI(
      std::string_view uri) const {
    constexpr std::string_view prefix = "blob://nucleus/";
    if (!uri.starts_with(prefix)) return std::nullopt;
    const auto query = uri.find('?');
    const auto idEnd = query == std::string_view::npos ? uri.size() : query;
    if (idEnd == prefix.size()) return std::nullopt;
    BlobDescriptor descriptor;
    descriptor.id =
        std::string(uri.substr(prefix.size(), idEnd - prefix.size()));
    if (query == std::string_view::npos) {
      std::lock_guard lock(mutex_);
      const auto found = blobs_.find(descriptor.id);
      if (found == blobs_.end()) return std::nullopt;
      descriptor.size = found->second.size();
    } else {
      const std::string parameters(uri.substr(query + 1));
      const auto offsetStart = parameters.find("offset=");
      const auto sizeStart = parameters.find("size=");
      if (offsetStart == std::string::npos || sizeStart == std::string::npos) {
        return std::nullopt;
      }
      try {
        descriptor.offset = std::stoull(parameters.substr(offsetStart + 7));
        descriptor.size = std::stoull(parameters.substr(sizeStart + 5));
      } catch (...) {
        return std::nullopt;
      }
    }
    return resolve(descriptor);
  }

  void release(const std::string &id) {
    std::lock_guard lock(mutex_);
    if (auto found = blobs_.find(id); found != blobs_.end()) {
      totalBytes_ -= found->second.size();
      blobs_.erase(found);
    }
  }

  void setSocketBlobMode(std::int32_t id, bool enabled) {
    std::lock_guard lock(mutex_);
    if (enabled) {
      blobSockets_.insert(id);
    } else {
      blobSockets_.erase(id);
    }
  }

  bool socketUsesBlobs(std::int32_t id) const {
    std::lock_guard lock(mutex_);
    return blobSockets_.contains(id);
  }

private:
  mutable std::mutex mutex_;
  std::unordered_map<std::string, std::vector<std::uint8_t>> blobs_;
  std::unordered_set<std::int32_t> blobSockets_;
  std::size_t totalBytes_{0};
  std::atomic<std::uint64_t> nextID_{1};
};

namespace {

class BlobCollector final : public facebook::jsi::HostObject {
public:
  BlobCollector(std::shared_ptr<BlobStore> store, std::string id)
      : store_(std::move(store)), id_(std::move(id)) {}
  ~BlobCollector() override { store_->release(id_); }

private:
  std::shared_ptr<BlobStore> store_;
  std::string id_;
};

class BlobModule final : public TurboModule {
public:
  BlobModule(std::shared_ptr<facebook::react::CallInvoker> invoker,
             std::shared_ptr<BlobStore> store,
             std::shared_ptr<NetworkTransportOwner> transport)
      : TurboModule("BlobModule", std::move(invoker)),
        store_(std::move(store)), transport_(std::move(transport)) {}

protected:
  Value create(Runtime &runtime, const PropNameID &property) override {
    const auto name = property.utf8(runtime);
    if (name == "getConstants") {
      return facebook::jsi::Function::createFromHostFunction(
          runtime, property, 0,
          [](Runtime &runtime, const Value &, const Value *, std::size_t) {
            Object constants(runtime);
            constants.setProperty(runtime, "BLOB_URI_SCHEME", "blob");
            constants.setProperty(runtime, "BLOB_URI_HOST", "nucleus");
            return constants;
          });
    }
    if (name == "addNetworkingHandler") {
      return voidFunction(runtime, property, 0,
                          [](Runtime &, const Value *, std::size_t) {});
    }
    if (name == "addWebSocketHandler" || name == "removeWebSocketHandler") {
      const bool enabled = name == "addWebSocketHandler";
      return voidFunction(
          runtime, property, 1,
          [store = store_, enabled](Runtime &runtime, const Value *arguments,
                                    std::size_t count) {
            if (count != 1 || !arguments[0].isNumber()) {
              throw JSError(runtime, "WebSocket id must be a number");
            }
            store->setSocketBlobMode(
                static_cast<std::int32_t>(arguments[0].asNumber()), enabled);
          });
    }
    if (name == "sendOverSocket") {
      return voidFunction(
          runtime, property, 2,
          [store = store_, transport = transport_](
              Runtime &runtime, const Value *arguments, std::size_t count) {
            if (count != 2 || !arguments[0].isObject() ||
                !arguments[1].isNumber()) {
              throw JSError(runtime, "invalid Blob WebSocket send");
            }
            const auto descriptor = descriptorFromObject(
                runtime, arguments[0].asObject(runtime));
            const auto bytes = store->resolve(descriptor);
            if (!bytes) throw JSError(runtime, "the specified blob is invalid");
            transport->sendWebSocketBinary(
                static_cast<std::int32_t>(arguments[1].asNumber()), *bytes);
          });
    }
    if (name == "createFromParts") {
      return voidFunction(
          runtime, property, 2,
          [store = store_](Runtime &runtime, const Value *arguments,
                           std::size_t count) {
            if (count != 2 || !arguments[0].isObject() ||
                !arguments[0].asObject(runtime).isArray(runtime)) {
              throw JSError(runtime, "Blob parts must be an array");
            }
            const auto id = valueString(runtime, arguments[1], "blob id");
            const auto parts = arguments[0].asObject(runtime).asArray(runtime);
            std::vector<std::uint8_t> output;
            for (std::size_t index = 0; index < parts.size(runtime); ++index) {
              const auto partValue = parts.getValueAtIndex(runtime, index);
              if (!partValue.isObject()) {
                throw JSError(runtime, "Blob part must be an object");
              }
              const auto part = partValue.asObject(runtime);
              const auto type = valueString(
                  runtime, part.getProperty(runtime, "type"), "Blob part type");
              if (type == "string") {
                const auto string = valueString(
                    runtime, part.getProperty(runtime, "data"), "Blob string");
                appendString(output, string);
              } else if (type == "blob") {
                const auto data = part.getProperty(runtime, "data");
                if (!data.isObject()) {
                  throw JSError(runtime, "Blob part data must be an object");
                }
                const auto bytes = store->resolve(
                    descriptorFromObject(runtime, data.asObject(runtime)));
                if (!bytes) {
                  throw JSError(runtime, "Blob part references invalid data");
                }
                appendBytes(output, *bytes);
              } else {
                throw JSError(runtime, "unsupported Blob part type");
              }
            }
            std::string error;
            if (!store->store(id, std::move(output), error)) {
              throw JSError(runtime, error);
            }
          });
    }
    if (name == "release") {
      return voidFunction(
          runtime, property, 1,
          [store = store_](Runtime &runtime, const Value *arguments,
                           std::size_t) {
            store->release(valueString(runtime, arguments[0], "blob id"));
          });
    }
    return Value::undefined();
  }

private:
  using VoidBody =
      std::function<void(Runtime &, const Value *, std::size_t)>;

  static Value voidFunction(Runtime &runtime, const PropNameID &property,
                            unsigned int argumentCount, VoidBody body) {
    return facebook::jsi::Function::createFromHostFunction(
        runtime, property, argumentCount,
        [body = std::move(body)](Runtime &runtime, const Value &,
                                 const Value *arguments, std::size_t count) {
          body(runtime, arguments, count);
          return Value::undefined();
        });
  }

  std::shared_ptr<BlobStore> store_;
  std::shared_ptr<NetworkTransportOwner> transport_;
};

class FileReaderModule final : public TurboModule {
public:
  FileReaderModule(std::shared_ptr<facebook::react::CallInvoker> invoker,
                   std::shared_ptr<BlobStore> store)
      : TurboModule("FileReaderModule", std::move(invoker)),
        store_(std::move(store)) {}

protected:
  Value create(Runtime &runtime, const PropNameID &property) override {
    const auto name = property.utf8(runtime);
    if (name != "readAsDataURL" && name != "readAsText") {
      return Value::undefined();
    }
    const bool dataURL = name == "readAsDataURL";
    return facebook::jsi::Function::createFromHostFunction(
        runtime, property, dataURL ? 1 : 2,
        [store = store_, dataURL](Runtime &runtime, const Value &,
                                  const Value *arguments, std::size_t count) {
          return facebook::react::createPromiseAsJSIValue(
              runtime,
              [store, dataURL, descriptor = descriptorFromObject(
                                   runtime, arguments[0].asObject(runtime)),
               encoding = count > 1 && arguments[1].isString()
                              ? arguments[1].asString(runtime).utf8(runtime)
                              : std::string("UTF-8")](
                  Runtime &runtime,
                  const std::shared_ptr<facebook::react::Promise> &promise) {
                const auto bytes = store->resolve(descriptor);
                if (!bytes) {
                  promise->reject("the specified blob is invalid");
                  return;
                }
                if (dataURL) {
                  const auto type = descriptor.type.empty()
                                        ? "application/octet-stream"
                                        : descriptor.type;
                  const auto result =
                      "data:" + type + ";base64," + encodeBase64(*bytes);
                  promise->resolve(String::createFromUtf8(runtime, result));
                  return;
                }
                std::string normalized;
                std::transform(encoding.begin(), encoding.end(),
                               std::back_inserter(normalized),
                               [](unsigned char value) {
                                 return static_cast<char>(std::tolower(value));
                               });
                if (normalized != "utf-8" && normalized != "utf8") {
                  promise->reject("only UTF-8 Blob text decoding is supported");
                  return;
                }
                promise->resolve(String::createFromUtf8(
                    runtime, bytesAsString(*bytes)));
              });
        });
  }

private:
  std::shared_ptr<BlobStore> store_;
};

Headers headersFromArray(Runtime &runtime, const Value &value) {
  if (!value.isObject() || !value.asObject(runtime).isArray(runtime)) {
    throw JSError(runtime, "headers must be an array");
  }
  Headers headers;
  const auto array = value.asObject(runtime).asArray(runtime);
  headers.reserve(array.size(runtime));
  for (std::size_t index = 0; index < array.size(runtime); ++index) {
    const auto item = array.getValueAtIndex(runtime, index);
    if (!item.isObject() || !item.asObject(runtime).isArray(runtime)) {
      throw JSError(runtime, "header must be a pair");
    }
    const auto pair = item.asObject(runtime).asArray(runtime);
    if (pair.size(runtime) != 2) throw JSError(runtime, "header must be a pair");
    headers.emplace_back(
        valueString(runtime, pair.getValueAtIndex(runtime, 0), "header name"),
        valueString(runtime, pair.getValueAtIndex(runtime, 1), "header value"));
  }
  return headers;
}

std::vector<std::pair<std::string, std::string>> objectHeaders(
    Runtime &runtime, const Object &object) {
  std::vector<std::pair<std::string, std::string>> result;
  const auto names = object.getPropertyNames(runtime);
  result.reserve(names.size(runtime));
  for (std::size_t index = 0; index < names.size(runtime); ++index) {
    const auto name = names.getValueAtIndex(runtime, index)
                          .asString(runtime)
                          .utf8(runtime);
    const auto value = valueString(runtime, object.getProperty(runtime, name.c_str()),
                                   "multipart header value");
    if (!validHeaderName(name) || !validHeaderValue(value)) {
      throw JSError(runtime, "invalid multipart header");
    }
    result.emplace_back(name, value);
  }
  return result;
}

struct PreparedBody final {
  Body body;
  Headers headers;
};

PreparedBody prepareBody(Runtime &runtime, const Object &bodyObject,
                         Headers headers, const std::shared_ptr<BlobStore> &store,
                         std::uint32_t requestID) {
  PreparedBody result;
  result.headers = std::move(headers);
  const auto blob = bodyObject.getProperty(runtime, "blob");
  if (blob.isObject()) {
    const auto descriptor =
        descriptorFromObject(runtime, blob.asObject(runtime));
    const auto bytes = store->resolve(descriptor);
    if (!bytes) throw JSError(runtime, "request references an invalid blob");
    const auto hasContentType =
        std::any_of(result.headers.begin(), result.headers.end(), [](const auto &header) {
          std::string name = header.first;
          std::transform(name.begin(), name.end(), name.begin(),
                         [](unsigned char value) {
                           return static_cast<char>(std::tolower(value));
                         });
          return name == "content-type";
        });
    if (!descriptor.type.empty() && !hasContentType) {
      result.headers.emplace_back("Content-Type", descriptor.type);
    }
    result.body.string = bytesAsString(*bytes);
    return result;
  }

  const auto formData = bodyObject.getProperty(runtime, "formData");
  if (!formData.isObject()) return result;
  if (!formData.asObject(runtime).isArray(runtime)) {
    throw JSError(runtime, "multipart body must be an array");
  }
  const auto parts = formData.asObject(runtime).asArray(runtime);
  struct Part final {
    std::vector<std::pair<std::string, std::string>> headers;
    std::vector<std::uint8_t> bytes;
  };
  std::vector<Part> preparedParts;
  preparedParts.reserve(parts.size(runtime));
  for (std::size_t index = 0; index < parts.size(runtime); ++index) {
    const auto value = parts.getValueAtIndex(runtime, index);
    if (!value.isObject()) throw JSError(runtime, "invalid multipart part");
    const auto part = value.asObject(runtime);
    const auto partHeaders = part.getProperty(runtime, "headers");
    if (!partHeaders.isObject()) {
      throw JSError(runtime, "multipart part has no headers");
    }
    Part prepared{objectHeaders(runtime, partHeaders.asObject(runtime)), {}};
    const auto string = part.getProperty(runtime, "string");
    const auto uri = part.getProperty(runtime, "uri");
    if (string.isString()) {
      const auto text = string.asString(runtime).utf8(runtime);
      prepared.bytes.assign(text.begin(), text.end());
    } else if (uri.isString()) {
      const auto resolved =
          store->resolveURI(uri.asString(runtime).utf8(runtime));
      if (!resolved) throw JSError(runtime, "multipart URI is not a valid Blob URL");
      prepared.bytes = *resolved;
    } else {
      throw JSError(runtime, "multipart part has no string or Blob URI");
    }
    preparedParts.push_back(std::move(prepared));
  }

  static std::atomic<std::uint64_t> nextBoundary{1};
  std::string boundary;
  do {
    std::ostringstream stream;
    stream << "nucleus-" << std::hex << requestID << '-'
           << nextBoundary.fetch_add(1, std::memory_order_relaxed);
    boundary = stream.str();
  } while (std::any_of(preparedParts.begin(), preparedParts.end(),
                       [&boundary](const Part &part) {
                         return containsBytes(part.bytes, boundary);
                       }));

  std::vector<std::uint8_t> output;
  for (const auto &part : preparedParts) {
    appendString(output, "--" + boundary + "\r\n");
    for (const auto &[name, value] : part.headers) {
      appendString(output, name + ": " + value + "\r\n");
    }
    appendString(output, "\r\n");
    appendBytes(output, part.bytes);
    appendString(output, "\r\n");
  }
  appendString(output, "--" + boundary + "--\r\n");
  result.body.string = bytesAsString(output);
  result.headers.erase(
      std::remove_if(result.headers.begin(), result.headers.end(),
                     [](const auto &header) {
                       std::string name = header.first;
                       std::transform(name.begin(), name.end(), name.begin(),
                                      [](unsigned char value) {
                                        return static_cast<char>(std::tolower(value));
                                      });
                       return name == "content-type" || name == "content-length";
                     }),
      result.headers.end());
  result.headers.emplace_back(
      "Content-Type", "multipart/form-data; boundary=" + boundary);
  return result;
}

class BlobNetworkingModule final
    : public TurboModule,
      public std::enable_shared_from_this<BlobNetworkingModule> {
public:
  BlobNetworkingModule(
      std::shared_ptr<facebook::react::CallInvoker> invoker,
      std::shared_ptr<TurboModule> delegate, std::shared_ptr<BlobStore> store,
      std::shared_ptr<NetworkTransportOwner> transport)
      : TurboModule("Networking", std::move(invoker)),
        delegate_(std::move(delegate)), store_(std::move(store)),
        client_(makeHttpClient(std::move(transport))) {}

  ~BlobNetworkingModule() override {
    std::unordered_map<std::uint32_t, std::unique_ptr<IRequestToken>> requests;
    {
      std::lock_guard lock(mutex_);
      requests.swap(requests_);
    }
  }

protected:
  Value create(Runtime &runtime, const PropNameID &property) override {
    const auto name = property.utf8(runtime);
    if (name == "sendRequest") {
      return facebook::jsi::Function::createFromHostFunction(
          runtime, property, 9,
          [weak = weak_from_this(), delegate = delegate_, name](
              Runtime &runtime, const Value &, const Value *arguments,
              std::size_t count) {
            auto self = weak.lock();
            if (!self) return Value::undefined();
            if (count < 9 || !arguments[4].isObject()) {
              throw JSError(runtime, "invalid network request");
            }
            const auto body = arguments[4].asObject(runtime);
            const auto responseType =
                valueString(runtime, arguments[5], "response type");
            const bool custom = body.getProperty(runtime, "blob").isObject() ||
                                body.getProperty(runtime, "formData").isObject() ||
                                responseType == "blob";
            if (!custom) {
              const auto delegatedProperty =
                  PropNameID::forUtf8(runtime, name);
              auto function = delegate->get(runtime, delegatedProperty)
                                  .asObject(runtime)
                                  .asFunction(runtime);
              return function.call(runtime, arguments, count);
            }
            self->sendRequest(runtime, arguments, count, responseType);
            return Value::undefined();
          });
    }
    if (name == "abortRequest") {
      return facebook::jsi::Function::createFromHostFunction(
          runtime, property, 1,
          [weak = weak_from_this(), delegate = delegate_, name](
              Runtime &runtime, const Value &, const Value *arguments,
              std::size_t count) {
            const auto id = static_cast<std::uint32_t>(arguments[0].asNumber());
            if (auto self = weak.lock(); self && self->cancel(id)) {
              return Value::undefined();
            }
            const auto delegatedProperty = PropNameID::forUtf8(runtime, name);
            auto function = delegate->get(runtime, delegatedProperty)
                                .asObject(runtime)
                                .asFunction(runtime);
            return function.call(runtime, arguments, count);
          });
    }
    return delegate_->get(runtime, property);
  }

private:
  void sendRequest(Runtime &runtime, const Value *arguments, std::size_t,
                   const std::string &responseType) {
    const auto method = valueString(runtime, arguments[0], "method");
    const auto url = valueString(runtime, arguments[1], "URL");
    const auto requestID =
        static_cast<std::uint32_t>(arguments[2].asNumber());
    auto headers = headersFromArray(runtime, arguments[3]);
    auto prepared = prepareBody(runtime, arguments[4].asObject(runtime),
                                std::move(headers), store_, requestID);
    const bool incremental = arguments[6].isBool() && arguments[6].getBool();
    const auto timeout =
        static_cast<std::uint32_t>(arguments[7].asNumber());

    {
      std::lock_guard lock(mutex_);
      requests_.insert_or_assign(requestID, nullptr);
    }
    auto weak = weak_from_this();
    NetworkCallbacks callbacks{
        .onUploadProgress = [weak, requestID](std::int64_t sent,
                                              std::int64_t total) {
          if (auto self = weak.lock()) self->emitProgress("didSendNetworkData", requestID, sent, total);
        },
        .onResponse = [weak, requestID, url](std::uint16_t status,
                                             Headers headers) {
          if (auto self = weak.lock()) self->emitResponse(requestID, status, headers, url);
        },
        .onBody = [weak, requestID, responseType](
                      std::unique_ptr<folly::IOBuf> body) {
          if (auto self = weak.lock()) self->emitBody(requestID, responseType, *body);
        },
        .onBodyIncremental =
            [weak, requestID](std::int64_t received, std::int64_t total,
                              std::unique_ptr<folly::IOBuf> body) {
              const auto bytes = iobufBytes(*body);
              if (auto self = weak.lock()) {
                self->emitIncremental(requestID, bytes, received, total);
              }
              return static_cast<std::int64_t>(bytes.size());
            },
        .onBodyProgress = [weak, requestID](std::int64_t received,
                                            std::int64_t total) {
          if (auto self = weak.lock()) self->emitProgress("didReceiveNetworkDataProgress", requestID, received, total);
        },
        .onResponseComplete =
            [weak, requestID](std::string error, bool timedOut) {
              if (auto self = weak.lock()) self->complete(requestID, std::move(error), timedOut);
            },
        .sendIncrementalUpdates = incremental && responseType == "text",
        .sendProgressUpdates = incremental && responseType != "text"};
    auto token = client_->sendRequest(std::move(callbacks), method, url,
                                      prepared.headers, prepared.body, timeout,
                                      std::to_string(requestID));
    bool keep = false;
    {
      std::lock_guard lock(mutex_);
      if (auto found = requests_.find(requestID); found != requests_.end()) {
        found->second = std::move(token);
        keep = true;
      }
    }
    if (!keep && token) token->cancel();
  }

  bool cancel(std::uint32_t id) {
    std::unique_ptr<IRequestToken> token;
    {
      std::lock_guard lock(mutex_);
      const auto found = requests_.find(id);
      if (found == requests_.end()) return false;
      token = std::move(found->second);
      requests_.erase(found);
    }
    if (token) token->cancel();
    return true;
  }

  void emitProgress(const char *event, std::uint32_t id, std::int64_t value,
                    std::int64_t total) {
    emitDeviceEvent(event, [id, value, total](Runtime &runtime,
                                              std::vector<Value> &arguments) {
      Array payload(runtime, 3);
      payload.setValueAtIndex(runtime, 0, static_cast<double>(id));
      payload.setValueAtIndex(runtime, 1, static_cast<double>(value));
      payload.setValueAtIndex(runtime, 2, static_cast<double>(total));
      arguments.emplace_back(std::move(payload));
    });
  }

  void emitResponse(std::uint32_t id, std::uint16_t status,
                    const Headers &headers, const std::string &url) {
    emitDeviceEvent("didReceiveNetworkResponse",
                    [id, status, headers, url](Runtime &runtime,
                                               std::vector<Value> &arguments) {
      Array headerArray(runtime, headers.size());
      for (std::size_t index = 0; index < headers.size(); ++index) {
        Array pair(runtime, 2);
        pair.setValueAtIndex(runtime, 0,
                             String::createFromUtf8(runtime, headers[index].first));
        pair.setValueAtIndex(runtime, 1,
                             String::createFromUtf8(runtime, headers[index].second));
        headerArray.setValueAtIndex(runtime, index, std::move(pair));
      }
      Array payload(runtime, 4);
      payload.setValueAtIndex(runtime, 0, static_cast<double>(id));
      payload.setValueAtIndex(runtime, 1, static_cast<double>(status));
      payload.setValueAtIndex(runtime, 2, std::move(headerArray));
      payload.setValueAtIndex(runtime, 3, String::createFromUtf8(runtime, url));
      arguments.emplace_back(std::move(payload));
    });
  }

  void emitBody(std::uint32_t id, const std::string &responseType,
                const folly::IOBuf &body) {
    auto bytes = iobufBytes(body);
    if (responseType == "blob") {
      std::string error;
      auto descriptor = store_->storeGenerated(std::move(bytes), {}, error);
      if (!descriptor) {
        complete(id, std::move(error), false);
        return;
      }
      emitDeviceEvent("didReceiveNetworkData",
                      [id, descriptor = std::move(*descriptor)](
                          Runtime &runtime, std::vector<Value> &arguments) {
        Array payload(runtime, 2);
        payload.setValueAtIndex(runtime, 0, static_cast<double>(id));
        payload.setValueAtIndex(runtime, 1,
                                descriptorObject(runtime, descriptor));
        arguments.emplace_back(std::move(payload));
      });
      return;
    }
    const auto data = responseType == "base64" ? encodeBase64(bytes)
                                                : bytesAsString(bytes);
    emitDeviceEvent("didReceiveNetworkData",
                    [id, data](Runtime &runtime,
                               std::vector<Value> &arguments) {
      Array payload(runtime, 2);
      payload.setValueAtIndex(runtime, 0, static_cast<double>(id));
      payload.setValueAtIndex(runtime, 1,
                              String::createFromUtf8(runtime, data));
      arguments.emplace_back(std::move(payload));
    });
  }

  void emitIncremental(std::uint32_t id,
                       const std::vector<std::uint8_t> &bytes,
                       std::int64_t received, std::int64_t total) {
    const auto data = bytesAsString(bytes);
    emitDeviceEvent("didReceiveNetworkIncrementalData",
                    [id, data, received, total](Runtime &runtime,
                                                std::vector<Value> &arguments) {
      Array payload(runtime, 4);
      payload.setValueAtIndex(runtime, 0, static_cast<double>(id));
      payload.setValueAtIndex(runtime, 1, String::createFromUtf8(runtime, data));
      payload.setValueAtIndex(runtime, 2, static_cast<double>(received));
      payload.setValueAtIndex(runtime, 3, static_cast<double>(total));
      arguments.emplace_back(std::move(payload));
    });
  }

  void complete(std::uint32_t id, std::string error, bool timedOut) {
    std::unique_ptr<IRequestToken> token;
    {
      std::lock_guard lock(mutex_);
      const auto found = requests_.find(id);
      if (found == requests_.end()) return;
      token = std::move(found->second);
      requests_.erase(found);
    }
    emitDeviceEvent("didCompleteNetworkResponse",
                    [id, error = std::move(error), timedOut](
                        Runtime &runtime, std::vector<Value> &arguments) {
      Array payload(runtime, error.empty() ? 1 : 3);
      payload.setValueAtIndex(runtime, 0, static_cast<double>(id));
      if (!error.empty()) {
        payload.setValueAtIndex(runtime, 1,
                                String::createFromUtf8(runtime, error));
        payload.setValueAtIndex(runtime, 2, timedOut);
      }
      arguments.emplace_back(std::move(payload));
    });
  }

  std::shared_ptr<TurboModule> delegate_;
  std::shared_ptr<BlobStore> store_;
  std::unique_ptr<facebook::react::IHttpClient> client_;
  std::mutex mutex_;
  std::unordered_map<std::uint32_t, std::unique_ptr<IRequestToken>> requests_;
};

class BlobWebSocketModule final
    : public TurboModule,
      public std::enable_shared_from_this<BlobWebSocketModule> {
public:
  BlobWebSocketModule(
      std::shared_ptr<facebook::react::CallInvoker> invoker,
      std::shared_ptr<TurboModule> delegate, std::shared_ptr<BlobStore> store,
      std::shared_ptr<NetworkTransportOwner> transport)
      : TurboModule("WebSocketModule", std::move(invoker)),
        delegate_(std::move(delegate)), store_(std::move(store)),
        transport_(std::move(transport)) {}

protected:
  Value create(Runtime &runtime, const PropNameID &property) override {
    const auto name = property.utf8(runtime);
    if (name == "connect") {
      return facebook::jsi::Function::createFromHostFunction(
          runtime, property, 4,
          [weak = weak_from_this(), delegate = delegate_, name](
              Runtime &runtime, const Value &, const Value *arguments,
              std::size_t count) {
            if (count != 4 || !arguments[3].isNumber()) {
              throw JSError(runtime, "invalid WebSocket connect");
            }
            if (auto self = weak.lock()) {
              const auto id =
                  static_cast<std::int32_t>(arguments[3].asNumber());
              self->transport_->prepareWebSocket(
                  id, [weak](std::int32_t socketID,
                             const NetworkBytes &bytes) {
                    if (auto self = weak.lock()) {
                      self->didReceiveBinary(socketID, bytes);
                    }
                  });
            }
            const auto delegatedProperty = PropNameID::forUtf8(runtime, name);
            auto function = delegate->get(runtime, delegatedProperty)
                                .asObject(runtime)
                                .asFunction(runtime);
            return function.call(runtime, arguments, count);
          });
    }
    if (name == "sendBinary") {
      return facebook::jsi::Function::createFromHostFunction(
          runtime, property, 2,
          [transport = transport_](Runtime &runtime, const Value &,
                                   const Value *arguments, std::size_t count) {
            if (count != 2 || !arguments[1].isNumber()) {
              throw JSError(runtime, "invalid binary WebSocket send");
            }
            const auto encoded = valueString(
                runtime, arguments[0], "base64 WebSocket payload");
            const auto bytes = decodeBase64(encoded);
            if (!bytes) throw JSError(runtime, "invalid base64 WebSocket payload");
            transport->sendWebSocketBinary(
                static_cast<std::int32_t>(arguments[1].asNumber()), *bytes);
            return Value::undefined();
          });
    }
    return delegate_->get(runtime, property);
  }

private:
  void didReceiveBinary(std::int32_t id, const NetworkBytes &networkBytes) {
    std::vector<std::uint8_t> bytes(networkBytes.begin(), networkBytes.end());
    if (store_->socketUsesBlobs(id)) {
      std::string error;
      auto descriptor = store_->storeGenerated(std::move(bytes), {}, error);
      if (!descriptor) return;
      emitDeviceEvent("websocketMessage",
                      [id, descriptor = std::move(*descriptor)](
                          Runtime &runtime, std::vector<Value> &arguments) {
        Object payload(runtime);
        payload.setProperty(runtime, "id", id);
        payload.setProperty(runtime, "type", "blob");
        payload.setProperty(runtime, "data",
                            descriptorObject(runtime, descriptor));
        arguments.emplace_back(std::move(payload));
      });
    } else {
      const auto encoded = encodeBase64(bytes);
      emitDeviceEvent("websocketMessage",
                      [id, encoded](Runtime &runtime,
                                    std::vector<Value> &arguments) {
        Object payload(runtime);
        payload.setProperty(runtime, "id", id);
        payload.setProperty(runtime, "type", "binary");
        payload.setProperty(runtime, "data",
                            String::createFromUtf8(runtime, encoded));
        arguments.emplace_back(std::move(payload));
      });
    }
  }

  std::shared_ptr<TurboModule> delegate_;
  std::shared_ptr<BlobStore> store_;
  std::shared_ptr<NetworkTransportOwner> transport_;
};

} // namespace

std::shared_ptr<BlobStore> makeBlobStore() {
  return std::make_shared<BlobStore>();
}

void installBlobCollectorProvider(Runtime &runtime,
                                  std::shared_ptr<BlobStore> store) {
  auto provider = facebook::jsi::Function::createFromHostFunction(
      runtime, PropNameID::forAscii(runtime, "__blobCollectorProvider"), 1,
      [store = std::move(store)](Runtime &runtime, const Value &,
                                 const Value *arguments, std::size_t count) {
        if (count != 1) throw JSError(runtime, "Blob collector needs an id");
        auto collector = std::make_shared<BlobCollector>(
            store, valueString(runtime, arguments[0], "blob id"));
        return Object::createFromHostObject(runtime, std::move(collector));
      });
  runtime.global().setProperty(runtime, "__blobCollectorProvider",
                               std::move(provider));
}

std::shared_ptr<TurboModule>
makeBlobModule(std::shared_ptr<facebook::react::CallInvoker> invoker,
               std::shared_ptr<BlobStore> store,
               std::shared_ptr<NetworkTransportOwner> transport) {
  return std::make_shared<BlobModule>(std::move(invoker), std::move(store),
                                      std::move(transport));
}

std::shared_ptr<TurboModule>
makeFileReaderModule(std::shared_ptr<facebook::react::CallInvoker> invoker,
                     std::shared_ptr<BlobStore> store) {
  return std::make_shared<FileReaderModule>(std::move(invoker),
                                             std::move(store));
}

std::shared_ptr<TurboModule> makeBlobNetworkingModule(
    std::shared_ptr<facebook::react::CallInvoker> invoker,
    std::shared_ptr<TurboModule> delegate, std::shared_ptr<BlobStore> store,
    std::shared_ptr<NetworkTransportOwner> transport) {
  return std::make_shared<BlobNetworkingModule>(
      std::move(invoker), std::move(delegate), std::move(store),
      std::move(transport));
}

std::shared_ptr<TurboModule> makeBlobWebSocketModule(
    std::shared_ptr<facebook::react::CallInvoker> invoker,
    std::shared_ptr<TurboModule> delegate, std::shared_ptr<BlobStore> store,
    std::shared_ptr<NetworkTransportOwner> transport) {
  return std::make_shared<BlobWebSocketModule>(
      std::move(invoker), std::move(delegate), std::move(store),
      std::move(transport));
}

} // namespace nucleus::react
