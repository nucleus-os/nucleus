#pragma once

#include <memory>

#include <ReactCommon/CallInvoker.h>
#include <ReactCommon/TurboModule.h>
#include <jsi/jsi.h>

namespace nucleus::react {

class BlobStore;
class NetworkTransportOwner;

std::shared_ptr<BlobStore> makeBlobStore();

void installBlobCollectorProvider(facebook::jsi::Runtime &runtime,
                                  std::shared_ptr<BlobStore> store);

std::shared_ptr<facebook::react::TurboModule>
makeBlobModule(std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
               std::shared_ptr<BlobStore> store,
               std::shared_ptr<NetworkTransportOwner> transport);

std::shared_ptr<facebook::react::TurboModule>
makeFileReaderModule(std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
                     std::shared_ptr<BlobStore> store);

std::shared_ptr<facebook::react::TurboModule> makeBlobNetworkingModule(
    std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
    std::shared_ptr<facebook::react::TurboModule> delegate,
    std::shared_ptr<BlobStore> store,
    std::shared_ptr<NetworkTransportOwner> transport);

std::shared_ptr<facebook::react::TurboModule> makeBlobWebSocketModule(
    std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
    std::shared_ptr<facebook::react::TurboModule> delegate,
    std::shared_ptr<BlobStore> store,
    std::shared_ptr<NetworkTransportOwner> transport);

} // namespace nucleus::react
