foreach(_nucleus_cxx_root IN ITEMS "${LLVM_BINARY_DIR}" "${CMAKE_BINARY_DIR}")
  if(NOT "${_nucleus_cxx_root}" STREQUAL "")
    set(_nucleus_cxx_dir "${_nucleus_cxx_root}/include/c++")
    if(IS_SYMLINK "${_nucleus_cxx_dir}")
      file(REMOVE "${_nucleus_cxx_dir}")
    endif()
    file(MAKE_DIRECTORY "${_nucleus_cxx_dir}/v1")
  endif()
endforeach()

set(_nucleus_blocks_link_flags
    "-Wl,--as-needed,-lBlocksRuntime,--no-as-needed")
foreach(_kind IN ITEMS EXE SHARED MODULE)
  set("CMAKE_${_kind}_LINKER_FLAGS"
      "${_nucleus_blocks_link_flags}"
      CACHE STRING "Nucleus host toolchain linker flags" FORCE)
endforeach()
