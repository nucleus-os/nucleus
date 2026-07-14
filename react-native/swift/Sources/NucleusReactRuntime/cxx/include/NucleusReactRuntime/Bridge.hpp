#pragma once

#include <string>
#include <utility>

namespace nucleus::react {

class HelloBridge final {
 public:
  explicit HelloBridge(std::string name) : name_(std::move(name)) {}

  std::string greet() const {
    return "hello, " + name_;
  }

 private:
  std::string name_;
};

} // namespace nucleus::react
