#pragma once

namespace nucleus::react {

struct FabricMountReport {
  unsigned int commitCount;
  unsigned int mutationCount;
};

bool hermesCanCreateRuntime() noexcept;
unsigned int hermesBytecodeVersion() noexcept;
bool hermesIntlDateTimeFormatWorks() noexcept;

} // namespace nucleus::react
