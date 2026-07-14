#pragma once

namespace nucleus::react {

struct FabricMountReport {
  unsigned int commitCount;
  unsigned int mutationCount;
};

bool hermesCanCreateRuntime();
unsigned int hermesBytecodeVersion();
bool hermesIntlDateTimeFormatWorks();

} // namespace nucleus::react
