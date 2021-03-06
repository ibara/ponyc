# Determine the operating system
OSTYPE ?=

ifeq ($(OS),Windows_NT)
  OSTYPE = windows
else
  UNAME_S := $(shell uname -s)

  ifeq ($(UNAME_S),Linux)
    OSTYPE = linux

    ifndef AR
      ifneq (,$(shell which gcc-ar 2> /dev/null))
        AR = gcc-ar
      endif
    endif

    ALPINE=$(wildcard /etc/alpine-release)
  endif

  ifeq ($(UNAME_S),Darwin)
    OSTYPE = osx
  endif

  ifeq ($(UNAME_S),FreeBSD)
    OSTYPE = bsd
    CXX = c++
  endif

  ifeq ($(UNAME_S),DragonFly)
    OSTYPE = bsd
    CXX = c++
  endif

  ifeq ($(UNAME_S),OpenBSD)
    OSTYPE = bsd
    CXX = c++
  endif
endif

ifdef LTO_PLUGIN
  lto := yes
endif

# Default settings (silent release build).
config ?= release
arch ?= native
tune ?= generic
cpu ?= $(arch)
fpu ?= 
bits ?= $(shell getconf LONG_BIT)

ifndef verbose
  SILENT = @
else
  SILENT =
endif

ifneq ($(wildcard .git),)
  tag := $(shell cat VERSION)-$(shell git rev-parse --short HEAD)
else
  tag := $(shell cat VERSION)
endif

version_str = "$(tag) [$(config)]\ncompiled with: llvm $(llvm_version) \
  -- "$(compiler_version)

# package_name, _version, and _iteration can be overridden by Travis or AppVeyor
package_base_version ?= $(tag)
package_iteration ?= "1"
package_name ?= "ponyc"
package_version = $(package_base_version)-$(package_iteration)
archive = $(package_name)-$(package_version).tar
package = build/$(package_name)-$(package_version)

prefix ?= /usr/local
bindir ?= $(prefix)/bin
includedir ?= $(prefix)/include
libdir ?= $(prefix)/lib

# destdir is for backward compatibility only, use ponydir instead.
ifdef destdir
  $(warning Please use ponydir instead of destdir.)
  ponydir ?= $(destdir)
endif
ponydir ?= $(libdir)/pony/$(tag)

symlink := yes

ifdef ponydir
  ifndef prefix
    symlink := no
  endif
endif

ifneq (,$(filter $(OSTYPE), osx bsd))
  symlink.flags = -sf
else
  symlink.flags = -srf
endif

ifneq (,$(filter $(OSTYPE), osx bsd))
  SED_INPLACE = sed -i -e
else
  SED_INPLACE = sed -i
endif

LIB_EXT ?= a
BUILD_FLAGS = -march=$(arch) -mtune=$(tune) -Werror -Wconversion \
  -Wno-sign-conversion -Wextra -Wall
LINKER_FLAGS = -march=$(arch) -mtune=$(tune) $(LDFLAGS)
AR_FLAGS ?= rcs
ALL_CFLAGS = -std=gnu11 -fexceptions \
  -DPONY_VERSION=\"$(tag)\" -DLLVM_VERSION=\"$(llvm_version)\" \
  -DPONY_COMPILER=\"$(CC)\" -DPONY_ARCH=\"$(arch)\" \
  -DBUILD_COMPILER=\"$(compiler_version)\" \
  -DPONY_BUILD_CONFIG=\"$(config)\" \
  -DPONY_VERSION_STR=\"$(version_str)\" \
  -D_FILE_OFFSET_BITS=64
ALL_CXXFLAGS = -std=gnu++11 -fno-rtti
LL_FLAGS = -mcpu=$(cpu)

# Determine pointer size in bits.
BITS := $(bits)
UNAME_M := $(shell uname -m)

ifeq ($(BITS),64)
  ifeq ($(UNAME_M),x86_64)
    ifeq (,$(filter $(arch), armv8-a))
      BUILD_FLAGS += -mcx16
      LINKER_FLAGS += -mcx16
    endif
  endif
endif

ifneq ($(fpu),)
  BUILD_FLAGS += -mfpu=$(fpu)
  LINKER_FLAGS += -mfpu=$(fpu)
endif

PONY_BUILD_DIR   ?= build/$(config)
PONY_SOURCE_DIR  ?= src
PONY_TEST_DIR ?= test
PONY_BENCHMARK_DIR ?= benchmark

ifdef use
  ifneq (,$(filter $(use), valgrind))
    ALL_CFLAGS += -DUSE_VALGRIND
    PONY_BUILD_DIR := $(PONY_BUILD_DIR)-valgrind
  endif

  ifneq (,$(filter $(use), coverage))
    ifneq (,$(shell $(CC) -v 2>&1 | grep clang))
      # clang
      COVERAGE_FLAGS = -O0 -fprofile-instr-generate -fcoverage-mapping
      LINKER_FLAGS += -fprofile-instr-generate -fcoverage-mapping
    else
      ifneq (,$(shell $(CC) -v 2>&1 | grep "gcc version"))
        # gcc
        COVERAGE_FLAGS = -O0 -fprofile-arcs -ftest-coverage
        LINKER_FLAGS += -fprofile-arcs
      else
        $(error coverage not supported for this compiler/platform)
      endif
      ALL_CFLAGS += $(COVERAGE_FLAGS)
      ALL_CXXFLAGS += $(COVERAGE_FLAGS)
    endif
    PONY_BUILD_DIR := $(PONY_BUILD_DIR)-coverage
  endif

  ifneq (,$(filter $(use), pooltrack))
    ALL_CFLAGS += -DUSE_POOLTRACK
    PONY_BUILD_DIR := $(PONY_BUILD_DIR)-pooltrack
  endif

  ifneq (,$(filter $(use), dtrace))
    DTRACE ?= $(shell which dtrace)
    ifeq (, $(DTRACE))
      $(error No dtrace compatible user application static probe generation tool found)
    endif

    ALL_CFLAGS += -DUSE_DYNAMIC_TRACE
    PONY_BUILD_DIR := $(PONY_BUILD_DIR)-dtrace
  endif

  ifneq (,$(filter $(use), actor_continuations))
    ALL_CFLAGS += -DUSE_ACTOR_CONTINUATIONS
    PONY_BUILD_DIR := $(PONY_BUILD_DIR)-actor_continuations
  endif

  ifneq (,$(filter $(use), scheduler_scaling_pthreads))
    ALL_CFLAGS += -DUSE_SCHEDULER_SCALING_PTHREADS
    PONY_BUILD_DIR := $(PONY_BUILD_DIR)-scheduler_scaling_pthreads
  endif
endif

ifdef config
  ifeq (,$(filter $(config),debug release))
    $(error Unknown configuration "$(config)")
  endif
endif

ifeq ($(config),release)
  BUILD_FLAGS += -O3 -DNDEBUG
  LL_FLAGS += -O3

  ifeq ($(lto),yes)
    BUILD_FLAGS += -flto -DPONY_USE_LTO
    LINKER_FLAGS += -flto

    ifdef LTO_PLUGIN
      AR_FLAGS += --plugin $(LTO_PLUGIN)
    endif

    ifneq (,$(filter $(OSTYPE),linux bsd))
      LINKER_FLAGS += -fuse-linker-plugin -fuse-ld=gold
    endif
  endif
else
  BUILD_FLAGS += -g -DDEBUG
endif

ifeq ($(OSTYPE),osx)
  ALL_CFLAGS += -mmacosx-version-min=10.8 -DUSE_SCHEDULER_SCALING_PTHREADS
  ALL_CXXFLAGS += -stdlib=libc++ -mmacosx-version-min=10.8
endif

ifndef LLVM_CONFIG
  ifneq (,$(shell which /usr/local/opt/llvm/bin/llvm-config 2> /dev/null))
    LLVM_CONFIG = /usr/local/opt/llvm/bin/llvm-config
  else ifneq (,$(shell which llvm-config-6.0 2> /dev/null))
    LLVM_CONFIG = llvm-config-6.0
  else ifneq (,$(shell which llvm-config-3.9 2> /dev/null))
    LLVM_CONFIG = llvm-config-3.9
  else ifneq (,$(shell which /usr/local/opt/llvm@3.9/bin/llvm-config 2> /dev/null))
    LLVM_CONFIG = /usr/local/opt/llvm@3.9/bin/llvm-config
  else ifneq (,$(shell which llvm-config39 2> /dev/null))
    LLVM_CONFIG = llvm-config39
  else ifneq (,$(shell which /usr/local/opt/llvm/bin/llvm-config 2> /dev/null))
    LLVM_CONFIG = /usr/local/opt/llvm/bin/llvm-config
  else ifneq (,$(shell which /usr/lib64/llvm3.9/bin/llvm-config 2> /dev/null))
    LLVM_CONFIG = /usr/lib64/llvm3.9/bin/llvm-config
  else ifneq (,$(shell which llvm-config 2> /dev/null))
    LLVM_CONFIG = llvm-config
  else ifneq (,$(shell which llvm-config-5.0 2> /dev/null))
    LLVM_CONFIG = llvm-config-5.0
  else ifneq (,$(shell which llvm-config-4.0 2> /dev/null))
    LLVM_CONFIG = llvm-config-4.0
  else ifneq (,$(shell which /usr/local/opt/llvm@4.0/bin/llvm-config 2> /dev/null))
    LLVM_CONFIG = /usr/local/opt/llvm@4.0/bin/llvm-config
  else ifneq (,$(shell which /opt/llvm-3.9.1/bin/llvm-config 2> /dev/null))
    LLVM_CONFIG = /opt/llvm-3.9.1/bin/llvm-config
  else ifneq (,$(shell which /opt/llvm-5.0.1/bin/llvm-config 2> /dev/null))
    LLVM_CONFIG = /opt/llvm-5.0.1/bin/llvm-config
  else ifneq (,$(shell which /opt/llvm-5.0.0/bin/llvm-config 2> /dev/null))
    LLVM_CONFIG = /opt/llvm-5.0.0/bin/llvm-config
  else ifneq (,$(shell which /opt/llvm-4.0.0/bin/llvm-config 2> /dev/null))
    LLVM_CONFIG = /opt/llvm-4.0.0/bin/llvm-config
  else
    $(error No LLVM installation found!)
  endif
else ifeq (,$(shell which $(LLVM_CONFIG) 2> /dev/null))
  $(error No LLVM installation found!)
endif

LLVM_BINDIR := $(shell $(LLVM_CONFIG) --bindir 2> /dev/null)

LLVM_LINK := $(LLVM_BINDIR)/llvm-link
LLVM_OPT := $(LLVM_BINDIR)/opt
LLVM_LLC := $(LLVM_BINDIR)/llc
LLVM_AS := $(LLVM_BINDIR)/llvm-as
llvm_build_mode := $(shell $(LLVM_CONFIG) --build-mode)
ifeq (Release,$(llvm_build_mode))
  LLVM_BUILD_MODE=LLVM_BUILD_MODE_Release
else ifeq (RelWithDebInfo,$(llvm_build_mode))
  LLVM_BUILD_MODE=LLVM_BUILD_MODE_RelWithDebInfo
else ifeq (Debug,$(llvm_build_mode))
  LLVM_BUILD_MODE=LLVM_BUILD_MODE_Debug
else
  $(error "Uknown llvm build-mode of $(llvm_build_mode)", aborting)
endif



llvm_version := $(shell $(LLVM_CONFIG) --version)

ifeq (,$(LLVM_LINK_STATIC))
  ifneq (,$(filter $(use), llvm_link_static))
    LLVM_LINK_STATIC=--link-static
    $(warning "linking llvm statically")
  endif
endif

ifeq ($(OSTYPE),osx)
  ifneq (,$(shell which $(LLVM_BINDIR)/llvm-ar 2> /dev/null))
    AR = $(LLVM_BINDIR)/llvm-ar
    AR_FLAGS := rcs
  else
    AR = /usr/bin/ar
    AR_FLAGS := -rcs
  endif
endif

ifeq ($(llvm_version),3.9.1)
else ifeq ($(llvm_version),4.0.1)
  $(warning WARNING: LLVM 4 support is experimental and may result in decreased performance or crashes)
else ifeq ($(llvm_version),5.0.0)
  $(warning WARNING: LLVM 5 support is experimental and may result in decreased performance or crashes)
else ifeq ($(llvm_version),5.0.1)
  $(warning WARNING: LLVM 5 support is experimental and may result in decreased performance or crashes)
else ifeq ($(llvm_version),6.0.0)
  $(warning WARNING: LLVM 6 support is experimental and may result in decreased performance or crashes)
else ifeq ($(llvm_version),6.0.1)
  $(warning WARNING: LLVM 6 support is experimental and may result in decreased performance or crashes)
else
  $(warning WARNING: Unsupported LLVM version: $(llvm_version))
  $(warning Please use LLVM 3.9.1)
endif

compiler_version := "$(shell $(CC) --version | sed -n 1p)"

ifeq ($(runtime-bitcode),yes)
  ifeq (,$(shell $(CC) -v 2>&1 | grep clang))
    $(error Compiling the runtime as a bitcode file requires clang)
  endif
endif

# Set default ssl version
ifdef default_ssl
  ifeq ("openssl_0.9.0","$(default_ssl)")
    default_ssl_valid:=ok
  endif
  ifeq ("openssl_1.1.0","$(default_ssl)")
    default_ssl_valid:=ok
  endif
  ifeq (ok,$(default_ssl_valid))
    $(warning default_ssl is $(default_ssl))
  else
    $(error default_ssl=$(default_ssl) is invalid, expecting one of openssl_0.9.0 or openssl_1.1.0)
  endif
  BUILD_FLAGS += -DPONY_DEFAULT_SSL=\"$(default_ssl)\"
endif

makefile_abs_path := $(realpath $(lastword $(MAKEFILE_LIST)))
packages_abs_src := $(shell dirname $(makefile_abs_path))/packages

$(shell mkdir -p $(PONY_BUILD_DIR))

lib   := $(PONY_BUILD_DIR)/lib/$(arch)
bin   := $(PONY_BUILD_DIR)
tests := $(PONY_BUILD_DIR)
benchmarks := $(PONY_BUILD_DIR)
obj   := $(PONY_BUILD_DIR)/obj-$(arch)

# Libraries. Defined as
# (1) a name and output directory
libponyc  := $(lib)
libponycc := $(lib)
libponyrt := $(lib)

ifeq ($(OSTYPE),linux)
  libponyrt-pic := $(lib)
endif

# Define special case rules for a targets source files. By default
# this makefile assumes that a targets source files can be found
# relative to a parent directory of the same name in $(PONY_SOURCE_DIR).
# Note that it is possible to collect files and exceptions with
# arbitrarily complex shell commands, as long as ':=' is used
# for definition, instead of '='.
ifneq ($(OSTYPE),windows)
  libponyc.except += src/libponyc/platform/signed.cc
  libponyc.except += src/libponyc/platform/unsigned.cc
  libponyc.except += src/libponyc/platform/vcvars.c
endif

# Handle platform specific code to avoid "no symbols" warnings.
libponyrt.except =

ifneq ($(OSTYPE),windows)
  libponyrt.except += src/libponyrt/asio/iocp.c
  libponyrt.except += src/libponyrt/lang/win_except.c
endif

ifneq ($(OSTYPE),linux)
  libponyrt.except += src/libponyrt/asio/epoll.c
endif

ifneq ($(OSTYPE),osx)
  ifneq ($(OSTYPE),bsd)
    libponyrt.except += src/libponyrt/asio/kqueue.c
  endif
endif

libponyrt.except += src/libponyrt/asio/sock.c
libponyrt.except += src/libponyrt/dist/dist.c
libponyrt.except += src/libponyrt/dist/proto.c

ifeq ($(OSTYPE),linux)
  libponyrt-pic.dir := src/libponyrt
  libponyrt-pic.except := $(libponyrt.except)
endif

# Third party, but requires compilation. Defined as
# (1) a name and output directory.
# (2) a list of the source files to be compiled.
libgtest := $(lib)
libgtest.dir := lib/gtest
libgtest.files := $(libgtest.dir)/gtest-all.cc
libgbenchmark := $(lib)
libgbenchmark.dir := lib/gbenchmark
libgbenchmark.srcdir := $(libgbenchmark.dir)/src

libblake2 := $(lib)
libblake2.dir := lib/blake2
libblake2.files := $(libblake2.dir)/blake2b-ref.c

# We don't add libponyrt here. It's a special case because it can be compiled
# to LLVM bitcode.
ifeq ($(OSTYPE), linux)
  libraries := libponyc libponyrt-pic libgtest libgbenchmark libblake2
else
  libraries := libponyc libgtest libgbenchmark libblake2
endif

# Third party, but prebuilt. Prebuilt libraries are defined as
# (1) a name (stored in prebuilt)
# (2) the linker flags necessary to link against the prebuilt libraries
# (3) a list of include directories for a set of libraries
# (4) a list of the libraries to link against
llvm.ldflags := $(shell $(LLVM_CONFIG) --ldflags $(LLVM_LINK_STATIC))
llvm.include.dir := $(shell $(LLVM_CONFIG) --includedir $(LLVM_LINK_STATIC))
include.paths := $(shell echo | $(CC) -v -E - 2>&1)
ifeq (,$(findstring $(llvm.include.dir),$(include.paths)))
# LLVM include directory is not in the existing paths;
# put it at the top of the system list
llvm.include := -isystem $(llvm.include.dir)
else
# LLVM include directory is already on the existing paths;
# do nothing
llvm.include :=
endif
llvm.libs    := $(shell $(LLVM_CONFIG) --libs $(LLVM_LINK_STATIC)) -lz -lncurses

ifeq ($(OSTYPE), bsd)
  llvm.libs += -lpthread -lexecinfo
endif

prebuilt := llvm

# Binaries. Defined as
# (1) a name and output directory.
ponyc := $(bin)

binaries := ponyc

# Tests suites are directly attached to the libraries they test.
libponyc.tests  := $(tests)
libponyrt.tests := $(tests)

tests := libponyc.tests libponyrt.tests

# Benchmark suites are directly attached to the libraries they test.
libponyc.benchmarks  := $(benchmarks)
libponyc.benchmarks.dir := benchmark/libponyc
libponyc.benchmarks.srcdir := $(libponyc.benchmarks.dir)
libponyrt.benchmarks := $(benchmarks)
libponyrt.benchmarks.dir := benchmark/libponyrt
libponyrt.benchmarks.srcdir := $(libponyrt.benchmarks.dir)

benchmarks := libponyc.benchmarks libponyrt.benchmarks

# Define include paths for targets if necessary. Note that these include paths
# will automatically apply to the test suite of a target as well.
libponyc.include := -I src/common/ -I src/libponyrt/ $(llvm.include) \
  -isystem lib/blake2
libponycc.include := -I src/common/ $(llvm.include)
libponyrt.include := -I src/common/ -I src/libponyrt/
libponyrt-pic.include := $(libponyrt.include)

libponyc.tests.include := -I src/common/ -I src/libponyc/ -I src/libponyrt \
  $(llvm.include) -isystem lib/gtest/
libponyrt.tests.include := -I src/common/ -I src/libponyrt/ -isystem lib/gtest/

libponyc.benchmarks.include := -I src/common/ -I src/libponyc/ \
  $(llvm.include) -isystem lib/gbenchmark/include/
libponyrt.benchmarks.include := -I src/common/ -I src/libponyrt/ -isystem \
  lib/gbenchmark/include/

ponyc.include := -I src/common/ -I src/libponyrt/ $(llvm.include)
libgtest.include := -isystem lib/gtest/
libgbenchmark.include := -isystem lib/gbenchmark/include/
libblake2.include := -isystem lib/blake2/

ifneq (,$(filter $(OSTYPE), osx bsd))
  libponyrt.include += -I /usr/local/include
endif

# target specific build options
libponyrt.tests.linkoptions += -rdynamic

ifneq ($(ALPINE),)
  libponyrt.tests.linkoptions += -lexecinfo
endif

libponyc.buildoptions = -D__STDC_CONSTANT_MACROS
libponyc.buildoptions += -D__STDC_FORMAT_MACROS
libponyc.buildoptions += -D__STDC_LIMIT_MACROS
libponyc.buildoptions += -DPONY_ALWAYS_ASSERT
libponyc.buildoptions += -DLLVM_BUILD_MODE=$(LLVM_BUILD_MODE)

libponyc.tests.buildoptions = -D__STDC_CONSTANT_MACROS
libponyc.tests.buildoptions += -D__STDC_FORMAT_MACROS
libponyc.tests.buildoptions += -D__STDC_LIMIT_MACROS
libponyc.tests.buildoptions += -DPONY_ALWAYS_ASSERT
libponyc.tests.buildoptions += -DPONY_PACKAGES_DIR=\"$(packages_abs_src)\"
libponyc.tests.buildoptions += -DLLVM_BUILD_MODE=$(LLVM_BUILD_MODE)

libponyc.tests.linkoptions += -rdynamic

ifneq ($(ALPINE),)
  libponyc.tests.linkoptions += -lexecinfo
endif

libponyc.benchmarks.buildoptions = -D__STDC_CONSTANT_MACROS
libponyc.benchmarks.buildoptions += -D__STDC_FORMAT_MACROS
libponyc.benchmarks.buildoptions += -D__STDC_LIMIT_MACROS
libponyc.benchmarks.buildoptions += -DLLVM_BUILD_MODE=$(LLVM_BUILD_MODE)

libgbenchmark.buildoptions := \
  -Wshadow -pedantic -pedantic-errors \
  -Wfloat-equal -fstrict-aliasing -Wstrict-aliasing -Wno-invalid-offsetof \
  -DHAVE_POSIX_REGEX -DHAVE_STD_REGEX -DHAVE_STEADY_CLOCK

ifneq ($(ALPINE),)
  libponyc.benchmarks.linkoptions += -lexecinfo
  libponyrt.benchmarks.linkoptions += -lexecinfo
endif

ponyc.buildoptions = $(libponyc.buildoptions)

ponyc.linkoptions += -rdynamic

ifneq ($(ALPINE),)
  ponyc.linkoptions += -lexecinfo
  BUILD_FLAGS += -DALPINE_LINUX
endif

ifeq ($(OSTYPE), linux)
  libponyrt-pic.buildoptions += -fpic
  libponyrt-pic.buildoptions-ll += -relocation-model=pic
endif

# Set default PIC for compiling if requested
ifdef default_pic
  ifeq (true,$(default_pic))
    libponyrt.buildoptions += -fpic
    libponyrt.buildoptions-ll += -relocation-model=pic
    BUILD_FLAGS += -DPONY_DEFAULT_PIC=true
  else
    ifneq (false,$(default_pic))
      $(error default_pic must be true or false)
    endif
  endif
endif

# target specific disabling of build options
libgtest.disable = -Wconversion -Wno-sign-conversion -Wextra
libgbenchmark.disable = -Wconversion -Wno-sign-conversion
libblake2.disable = -Wconversion -Wno-sign-conversion -Wextra

# Link relationships.
ponyc.links = libponyc libponyrt llvm libblake2
libponyc.tests.links = libgtest libponyc llvm libblake2
libponyc.tests.links.whole = libponyrt
libponyrt.tests.links = libgtest libponyrt
libponyc.benchmarks.links = libblake2 libgbenchmark libponyc libponyrt llvm
libponyrt.benchmarks.links = libgbenchmark libponyrt

ifeq ($(OSTYPE),linux)
  ponyc.links += libpthread libdl libatomic
  libponyc.tests.links += libpthread libdl libatomic
  libponyrt.tests.links += libpthread libdl libatomic
  libponyc.benchmarks.links += libpthread libdl libatomic
  libponyrt.benchmarks.links += libpthread libdl libatomic
endif

ifeq ($(OSTYPE),bsd)
  libponyc.tests.links += libpthread
  libponyrt.tests.links += libpthread
  libponyc.benchmarks.links += libpthread
  libponyrt.benchmarks.links += libpthread
endif

ifneq (, $(DTRACE))
  $(shell $(DTRACE) -h -s $(PONY_SOURCE_DIR)/common/dtrace_probes.d -o $(PONY_SOURCE_DIR)/common/dtrace_probes.h)
endif

# Overwrite the default linker for a target.
ponyc.linker = $(CXX) #compile as C but link as CPP (llvm)
libponyc.benchmarks.linker = $(CXX)
libponyrt.benchmarks.linker = $(CXX)

# make targets
targets := $(libraries) libponyrt $(binaries) $(tests) $(benchmarks)

.PHONY: all $(targets) install uninstall clean stats deploy prerelease check-version test-core test-stdlib-debug test-stdlib test-examples validate-grammar test-ci test-cross-ci benchmark stdlib stdlib-debug
all: $(targets)
	@:

# Dependencies
libponyc.depends := libponyrt libblake2
libponyc.tests.depends := libponyc libgtest
libponyrt.tests.depends := libponyrt libgtest
libponyc.benchmarks.depends := libponyc libgbenchmark
libponyrt.benchmarks.depends := libponyrt libgbenchmark
ponyc.depends := libponyc libponyrt

# Generic make section, edit with care.
##########################################################################
#                                                                        #
# DIRECTORY: Determines the source dir of a specific target              #
#                                                                        #
# ENUMERATE: Enumerates input and output files for a specific target     #
#                                                                        #
# CONFIGURE_COMPILER: Chooses a C or C++ compiler depending on the       #
#                     target file.                                       #
#                                                                        #
# CONFIGURE_LIBS: Builds a string of libraries to link for a targets     #
#                 link dependency.                                       #
#                                                                        #
# CONFIGURE_LINKER: Assembles the linker flags required for a target.    #
#                                                                        #
# EXPAND_COMMAND: Macro that expands to a proper make command for each   #
#                 target.                                                #
#                                                                        #
##########################################################################
define DIRECTORY
  $(eval sourcedir := )
  $(eval outdir := $(obj)/$(1))

  ifdef $(1).srcdir
    sourcedir := $($(1).srcdir)
  else ifdef $(1).dir
    sourcedir := $($(1).dir)
  else ifneq ($$(filter $(1),$(tests)),)
    sourcedir := $(PONY_TEST_DIR)/$(subst .tests,,$(1))
    outdir := $(obj)/tests/$(subst .tests,,$(1))
  else ifneq ($$(filter $(1),$(benchmarks)),)
    sourcedir := $(PONY_BENCHMARK_DIR)/$(subst .benchmarks,,$(1))
    outdir := $(obj)/benchmarks/$(subst .benchmarks,,$(1))
  else
    sourcedir := $(PONY_SOURCE_DIR)/$(1)
  endif
endef

define ENUMERATE
  $(eval sourcefiles := )

  ifdef $(1).files
    sourcefiles := $$($(1).files)
  else
    sourcefiles := $$(shell find $$(sourcedir) -type f -name "*.c" -or -name\
      "*.cc" -or -name "*.ll" | grep -v '.*/\.')
  endif

  ifdef $(1).except
    sourcefiles := $$(filter-out $($(1).except),$$(sourcefiles))
  endif
endef

define CONFIGURE_COMPILER
  ifeq ($(suffix $(1)),.cc)
    compiler := $(CXX)
    flags := $(ALL_CXXFLAGS) $(CXXFLAGS)
  endif

  ifeq ($(suffix $(1)),.c)
    compiler := $(CC)
    flags := $(ALL_CFLAGS) $(CFLAGS)
  endif
  
  ifeq ($(suffix $(1)),.bc)
    compiler := $(CC)
    flags := $(ALL_CFLAGS) $(CFLAGS)
  endif
  
  ifeq ($(suffix $(1)),.ll)
    compiler := $(CC)
    flags := $(ALL_CFLAGS) $(CFLAGS) -Wno-override-module
  endif
endef

define CONFIGURE_LIBS
  ifneq (,$$(filter $(1),$(prebuilt)))
    linkcmd += $($(1).ldflags)
    libs += $($(1).libs)
  else
    libs += $(subst lib,-l,$(1))
  endif
endef

define CONFIGURE_LIBS_WHOLE
  ifeq ($(OSTYPE),osx)
    wholelibs += -Wl,-force_load,$(lib)/$(1).a
  else
    wholelibs += $(subst lib,-l,$(1))
  endif
endef

define CONFIGURE_LINKER_WHOLE
  $(eval wholelibs :=)

  ifneq ($($(1).links.whole),)
    $(foreach lk,$($(1).links.whole),$(eval $(call CONFIGURE_LIBS_WHOLE,$(lk))))
    ifeq ($(OSTYPE),osx)
      libs += $(wholelibs)
    else
      libs += -Wl,--whole-archive $(wholelibs) -Wl,--no-whole-archive
    endif
  endif
endef

define CONFIGURE_LINKER
  $(eval linkcmd := $(LINKER_FLAGS) -L $(lib))
  $(eval linker := $(CC))
  $(eval libs :=)

  ifdef $(1).linker
    linker := $($(1).linker)
  else ifneq (,$$(filter .cc,$(suffix $(sourcefiles))))
    linker := $(CXX)
  endif

  $(eval $(call CONFIGURE_LINKER_WHOLE,$(1)))
  $(foreach lk,$($(1).links),$(eval $(call CONFIGURE_LIBS,$(lk))))
  linkcmd += $(libs) -L /usr/local/lib $($(1).linkoptions)
endef

define PREPARE
  $(eval $(call DIRECTORY,$(1)))
  $(eval $(call ENUMERATE,$(1)))
  $(eval $(call CONFIGURE_LINKER,$(1)))
  $(eval objectfiles  := $(subst $(sourcedir)/,$(outdir)/,$(addsuffix .o,\
    $(sourcefiles))))
  $(eval bitcodefiles := $(subst .o,.bc,$(objectfiles)))
  $(eval dependencies := $(subst .c,,$(subst .cc,,$(subst .ll,,$(subst .o,.d,\
    $(objectfiles))))))
endef

define EXPAND_OBJCMD
$(eval file := $(subst .o,,$(1)))
$(eval $(call CONFIGURE_COMPILER,$(file)))

ifeq ($(3),libponyrtyes)
  ifneq ($(suffix $(file)),.bc)
$(subst .c,,$(subst .cc,,$(subst .ll,,$(1)))): $(subst .c,.bc,$(subst .cc,.bc,$(subst .ll,.bc,$(file))))
	@echo '$$(notdir $$<)'
	@mkdir -p $$(dir $$@)
	$(SILENT)$(compiler) $(flags) -c -o $$@ $$<
  else ifeq ($(suffix $(subst .bc,,$(file))),.ll)
$(subst .ll,,$(1)): $(subst $(outdir)/,$(sourcedir)/,$(subst .bc,,$(file)))
	@echo '$$(notdir $$<)'
	@mkdir -p $$(dir $$@)
	$(SILENT)$(LLVM_AS) -o $$@ $$<
  else
$(subst .c,,$(subst .cc,,$(1))): $(subst $(outdir)/,$(sourcedir)/,$(subst .bc,,$(file)))
	@echo '$$(notdir $$<)'
	@mkdir -p $$(dir $$@)
	$(SILENT)$(compiler) -MMD -MP $(filter-out $($(2).disable),$(BUILD_FLAGS)) \
    $(flags) $($(2).buildoptions) -emit-llvm -c -o $$@ $$<  $($(2).include)
  endif
else ifeq ($(suffix $(file)),.ll)
$(subst .ll,,$(1)): $(subst $(outdir)/,$(sourcedir)/,$(file))
	@echo '$$(notdir $$<)'
	@mkdir -p $$(dir $$@)
	$(SILENT)$(LLVM_LLC) $(LL_FLAGS) $($(2).buildoptions-ll) -filetype=obj -o $$@ $$<
else
$(subst .c,,$(subst .cc,,$(1))): $(subst $(outdir)/,$(sourcedir)/,$(file))
	@echo '$$(notdir $$<)'
	@mkdir -p $$(dir $$@)
	$(SILENT)$(compiler) -MMD -MP $(filter-out $($(2).disable),$(BUILD_FLAGS)) \
    $(flags) $($(2).buildoptions) -c -o $$@ $$<  $($(2).include)
endif
endef

define EXPAND_COMMAND
$(eval $(call PREPARE,$(1)))
$(eval ofiles := $(subst .c,,$(subst .cc,,$(subst .ll,,$(objectfiles)))))
$(eval bcfiles := $(subst .c,,$(subst .cc,,$(subst .ll,,$(bitcodefiles)))))
$(eval depends := )
$(foreach d,$($(1).depends),$(eval depends += $($(d))/$(d).$(LIB_EXT)))

ifeq ($(1),libponyrt)
$($(1))/libponyrt.$(LIB_EXT): $(depends) $(ofiles)
	@mkdir -p $$(dir $$@)
	@echo 'Linking libponyrt'
    ifneq (,$(DTRACE))
    ifeq ($(OSTYPE), linux)
	@echo 'Generating dtrace object file (linux)'
	$(SILENT)$(DTRACE) -G -s $(PONY_SOURCE_DIR)/common/dtrace_probes.d -o $(PONY_BUILD_DIR)/dtrace_probes.o
	$(SILENT)$(AR) $(AR_FLAGS) $$@ $(ofiles) $(PONY_BUILD_DIR)/dtrace_probes.o
    else ifeq ($(OSTYPE), bsd)
	@echo 'Generating dtrace object file (bsd)'
	$(SILENT)rm -f $(PONY_BUILD_DIR)/dtrace_probes.o
	$(SILENT)$(DTRACE) -G -s $(PONY_SOURCE_DIR)/common/dtrace_probes.d -o $(PONY_BUILD_DIR)/dtrace_probes.o $(ofiles)
	$(SILENT)$(AR) $(AR_FLAGS) $$@ $(ofiles) $(PONY_BUILD_DIR)/dtrace_probes.o
	$(SILENT)$(AR) $(AR_FLAGS) $(PONY_BUILD_DIR)/libdtrace_probes.a $(PONY_BUILD_DIR)/dtrace_probes.o
    else
	$(SILENT)$(AR) $(AR_FLAGS) $$@ $(ofiles)
    endif
    else
	$(SILENT)$(AR) $(AR_FLAGS) $$@ $(ofiles)
    endif
  ifeq ($(runtime-bitcode),yes)
$($(1))/libponyrt.bc: $(depends) $(bcfiles)
	@mkdir -p $$(dir $$@)
	@echo 'Generating bitcode for libponyrt'
	$(SILENT)$(LLVM_LINK) -o $$@ $(bcfiles)
    ifeq ($(config),release)
	$(SILENT)$(LLVM_OPT) -O3 -o $$@ $$@
    endif
libponyrt: $($(1))/libponyrt.bc $($(1))/libponyrt.$(LIB_EXT)
  else
libponyrt: $($(1))/libponyrt.$(LIB_EXT)
  endif
else ifneq ($(filter $(1),$(libraries)),)
$($(1))/$(1).$(LIB_EXT): $(depends) $(ofiles)
	@mkdir -p $$(dir $$@)
	@echo 'Linking $(1)'
	$(SILENT)$(AR) $(AR_FLAGS) $$@ $(ofiles)
$(1): $($(1))/$(1).$(LIB_EXT)
else
$($(1))/$(1): $(depends) $(ofiles)
	@mkdir -p $$(dir $$@)
	@echo 'Linking $(1)'
	$(SILENT)$(linker) -o $$@ $(ofiles) $(linkcmd)
$(1): $($(1))/$(1)
endif

$(foreach bcfile,$(bitcodefiles),$(eval $(call EXPAND_OBJCMD,$(bcfile),$(1),$(addsuffix $(runtime-bitcode),$(1)))))
$(foreach ofile,$(objectfiles),$(eval $(call EXPAND_OBJCMD,$(ofile),$(1),$(addsuffix $(runtime-bitcode),$(1)))))
-include $(dependencies)
endef

$(foreach target,$(targets),$(eval $(call EXPAND_COMMAND,$(target))))


define EXPAND_INSTALL
ifeq ($(OSTYPE),linux)
install-libponyrt-pic: libponyrt-pic
	@mkdir -p $(destdir)/lib/$(arch)
	$(SILENT)cp $(lib)/libponyrt-pic.a $(DESTDIR)$(ponydir)/lib/$(arch)
endif
install-libponyrt: libponyrt
	@mkdir -p $(destdir)/lib/$(arch)
	$(SILENT)cp $(lib)/libponyrt.a $(DESTDIR)$(ponydir)/lib/$(arch)
ifeq ($(OSTYPE),linux)
install: libponyc libponyrt libponyrt-pic ponyc
else
install: libponyc libponyrt ponyc
endif
	@mkdir -p $(DESTDIR)$(ponydir)/bin
	@mkdir -p $(DESTDIR)$(ponydir)/lib/$(arch)
	@mkdir -p $(DESTDIR)$(ponydir)/include/pony/detail
	$(SILENT)cp $(lib)/libponyrt.a $(DESTDIR)$(ponydir)/lib/$(arch)
ifeq ($(OSTYPE),linux)
	$(SILENT)cp $(lib)/libponyrt-pic.a $(DESTDIR)$(ponydir)/lib/$(arch)
endif
ifneq ($(wildcard $(PONY_BUILD_DIR)/libponyrt.bc),)
	$(SILENT)cp $(PONY_BUILD_DIR)/libponyrt.bc $(DESTDIR)$(ponydir)/lib
endif
ifneq ($(wildcard $(lib)/libdtrace_probes.a),)
	$(SILENT)cp $(lib)/libdtrace_probes.a $(DESTDIR)$(ponydir)/lib/$(arch)
endif
	$(SILENT)cp $(lib)/libponyc.a $(DESTDIR)$(ponydir)/lib/$(arch)
	$(SILENT)cp $(bin)/ponyc $(DESTDIR)$(ponydir)/bin
	$(SILENT)cp src/libponyrt/pony.h $(DESTDIR)$(ponydir)/include
	$(SILENT)cp src/common/pony/detail/atomics.h $(DESTDIR)$(ponydir)/include/pony/detail
	$(SILENT)cp -r packages $(DESTDIR)$(ponydir)/
ifeq ($$(symlink),yes)
	@mkdir -p $(DESTDIR)$(bindir)
	@mkdir -p $(DESTDIR)$(libdir)
	@mkdir -p $(DESTDIR)$(includedir)/pony/detail
	$(SILENT)ln $(symlink.flags) $(ponydir)/bin/ponyc $(DESTDIR)$(bindir)/ponyc
	$(SILENT)ln $(symlink.flags) $(ponydir)/lib/$(arch)/libponyrt.a $(DESTDIR)$(libdir)/libponyrt.a
ifeq ($(OSTYPE),linux)
	$(SILENT)ln $(symlink.flags) $(ponydir)/lib/$(arch)/libponyrt-pic.a $(DESTDIR)$(libdir)/libponyrt-pic.a
endif
ifneq ($(wildcard $(DESTDIR)$(ponydir)/lib/libponyrt.bc),)
	$(SILENT)ln $(symlink.flags) $(ponydir)/lib/libponyrt.bc $(DESTDIR)$(libdir)/libponyrt.bc
endif
ifneq ($(wildcard $(PONY_BUILD_DIR)/libdtrace_probes.a),)
	$(SILENT)ln $(symlink.flags) $(ponydir)/lib/$(arch)/libdtrace_probes.a $(DESTDIR)$(libdir)/libdtrace_probes.a
endif
	$(SILENT)ln $(symlink.flags) $(ponydir)/lib/$(arch)/libponyc.a $(DESTDIR)$(libdir)/libponyc.a
	$(SILENT)ln $(symlink.flags) $(ponydir)/include/pony.h $(DESTDIR)$(includedir)/pony.h
	$(SILENT)ln $(symlink.flags) $(ponydir)/include/pony/detail/atomics.h $(DESTDIR)$(includedir)/pony/detail/atomics.h
endif
endef

$(eval $(call EXPAND_INSTALL))

define EXPAND_UNINSTALL
uninstall:
	-$(SILENT)rm -rf $(ponydir) 2>/dev/null ||:
	-$(SILENT)rm $(bindir)/ponyc 2>/dev/null ||:
	-$(SILENT)rm $(libdir)/libponyrt.a 2>/dev/null ||:
ifeq ($(OSTYPE),linux)
	-$(SILENT)rm $(libdir)/libponyrt-pic.a 2>/dev/null ||:
endif
ifneq ($(wildcard $(libdir)/libponyrt.bc),)
	-$(SILENT)rm $(libdir)/libponyrt.bc 2>/dev/null ||:
endif
ifneq ($(wildcard $(libdir)/libdtrace_probes.a),)
	-$(SILENT)rm $(libdir)/libdtrace_probes.a 2>/dev/null ||:
endif
	-$(SILENT)rm $(libdir)/libponyc.a 2>/dev/null ||:
	-$(SILENT)rm $(includedir)/pony.h 2>/dev/null ||:
	-$(SILENT)rm -r $(includedir)/pony/ 2>/dev/null ||:
endef

$(eval $(call EXPAND_UNINSTALL))

ifdef verbose
  bench_verbose = -DCMAKE_VERBOSE_MAKEFILE=true
endif

ifeq ($(lto),yes)
  bench_lto = -DBENCHMARK_ENABLE_LTO=true
endif

benchmark: all
	$(SILENT)echo "Running libponyc benchmarks..."
	$(SILENT)$(PONY_BUILD_DIR)/libponyc.benchmarks
	$(SILENT)echo "Running libponyrt benchmarks..."
	$(SILENT)(PONY_BUILD_DIR)/libponyrt.benchmarks

stdlib-debug: all
	$(SILENT)PONYPATH=.:$(PONYPATH) $(PONY_BUILD_DIR)/ponyc $(cross_args) -d -s --checktree --verify packages/stdlib

stdlib: all
	$(SILENT)PONYPATH=.:$(PONYPATH) $(PONY_BUILD_DIR)/ponyc $(cross_args) --checktree --verify packages/stdlib

test-stdlib-debug: stdlib-debug
	$(SILENT)$(cross_runner) ./stdlib --sequential
	$(SILENT)rm stdlib

test-stdlib: stdlib
	$(SILENT)$(cross_runner) ./stdlib --sequential
	$(SILENT)rm stdlib

test-core: all
	$(SILENT)$(PONY_BUILD_DIR)/libponyc.tests
	$(SILENT)$(PONY_BUILD_DIR)/libponyrt.tests

test: test-core test-stdlib test-examples

test-examples: all
	$(SILENT)PONYPATH=.:$(PONYPATH) find examples/*/* -name '*.pony' -print | xargs -n 1 dirname  | sort -u | grep -v ffi- | xargs -n 1 -I {} $(PONY_BUILD_DIR)/ponyc $(cross_args) -d -s --checktree -o {} {}

check-version: all
	$(SILENT)$(PONY_BUILD_DIR)/ponyc --version

validate-grammar: all
	$(SILENT)$(PONY_BUILD_DIR)/ponyc --antlr > pony.g.new
	$(SILENT)diff pony.g pony.g.new
	$(SILENT)rm pony.g.new

test-ci: all check-version test-core test-stdlib-debug test-stdlib test-examples validate-grammar

test-cross-ci: cross_args=--triple=$(cross_triple) --cpu=$(cross_cpu) --link-arch=$(cross_arch) --linker='$(cross_linker)'
test-cross-ci: cross_runner=$(QEMU_RUNNER)
test-cross-ci: test-ci

docs: all
	$(SILENT)$(PONY_BUILD_DIR)/ponyc packages/stdlib --docs --pass expr

docs-online: docs
	$(SILENT)$(SED_INPLACE) 's/site_name:\ stdlib/site_name:\ Pony Standard Library/' stdlib-docs/mkdocs.yml

# Note: linux only
define EXPAND_DEPLOY
deploy: test docs
	$(SILENT)bash .bintray.bash debian "$(package_base_version)" "$(package_name)"
	$(SILENT)bash .bintray.bash rpm    "$(package_base_version)" "$(package_name)"
	$(SILENT)bash .bintray.bash source "$(package_base_version)" "$(package_name)"
	$(SILENT)rm -rf build/bin
	@mkdir -p build/bin
	@mkdir -p $(package)/usr/bin
	@mkdir -p $(package)/usr/include/pony/detail
	@mkdir -p $(package)/usr/lib
	@mkdir -p $(package)/usr/lib/pony/$(package_version)/bin
	@mkdir -p $(package)/usr/lib/pony/$(package_version)/include/pony/detail
	@mkdir -p $(package)/usr/lib/pony/$(package_version)/lib
	$(SILENT)cp $(PONY_BUILD_DIR)/libponyc.a $(package)/usr/lib/pony/$(package_version)/lib
	$(SILENT)cp $(PONY_BUILD_DIR)/libponyrt.a $(package)/usr/lib/pony/$(package_version)/lib
ifeq ($(OSTYPE),linux)
	$(SILENT)cp $(PONY_BUILD_DIR)/libponyrt-pic.a $(package)/usr/lib/pony/$(package_version)/lib
endif
ifneq ($(wildcard $(PONY_BUILD_DIR)/libponyrt.bc),)
	$(SILENT)cp $(PONY_BUILD_DIR)/libponyrt.bc $(package)/usr/lib/pony/$(package_version)/lib
endif
ifneq ($(wildcard $(PONY_BUILD_DIR)/libdtrace_probes.a),)
	$(SILENT)cp $(PONY_BUILD_DIR)/libdtrace_probes.a $(package)/usr/lib/pony/$(package_version)/lib
endif
	$(SILENT)cp $(PONY_BUILD_DIR)/ponyc $(package)/usr/lib/pony/$(package_version)/bin
	$(SILENT)cp src/libponyrt/pony.h $(package)/usr/lib/pony/$(package_version)/include
	$(SILENT)cp src/common/pony/detail/atomics.h $(package)/usr/lib/pony/$(package_version)/include/pony/detail
	$(SILENT)ln -f -s /usr/lib/pony/$(package_version)/lib/libponyrt.a $(package)/usr/lib/libponyrt.a
ifeq ($(OSTYPE),linux)
	$(SILENT)ln -f -s /usr/lib/pony/$(package_version)/lib/libponyrt-pic.a $(package)/usr/lib/libponyrt-pic.a
endif
ifneq ($(wildcard /usr/lib/pony/$(package_version)/lib/libponyrt.bc),)
	$(SILENT)ln -f -s /usr/lib/pony/$(package_version)/lib/libponyrt.bc $(package)/usr/lib/libponyrt.bc
endif
ifneq ($(wildcard /usr/lib/pony/$(package_version)/lib/libdtrace_probes.a),)
	$(SILENT)ln -f -s /usr/lib/pony/$(package_version)/lib/libdtrace_probes.a $(package)/usr/lib/libdtrace_probes.a
endif
	$(SILENT)ln -f -s /usr/lib/pony/$(package_version)/lib/libponyc.a $(package)/usr/lib/libponyc.a
	$(SILENT)ln -f -s /usr/lib/pony/$(package_version)/bin/ponyc $(package)/usr/bin/ponyc
	$(SILENT)ln -f -s /usr/lib/pony/$(package_version)/include/pony.h $(package)/usr/include/pony.h
	$(SILENT)ln -f -s /usr/lib/pony/$(package_version)/include/pony/detail/atomics.h $(package)/usr/include/pony/detail/atomics.h
	$(SILENT)cp -r packages $(package)/usr/lib/pony/$(package_version)/
	$(SILENT)fpm -s dir -t deb -C $(package) -p build/bin --name $(package_name) --conflicts "ponyc-master" --conflicts "ponyc-release" --version $(package_base_version) --description "The Pony Compiler" --provides "ponyc" --provides "ponyc-release"
	$(SILENT)fpm -s dir -t rpm -C $(package) -p build/bin --name $(package_name) --conflicts "ponyc-master" --conflicts "ponyc-release" --version $(package_base_version) --description "The Pony Compiler" --provides "ponyc" --provides "ponyc-release" --depends "ponydep-ncurses"
	$(SILENT)git archive HEAD > build/bin/$(archive)
	$(SILENT)tar rvf build/bin/$(archive) stdlib-docs
	$(SILENT)bzip2 build/bin/$(archive)
	$(SILENT)rm -rf $(package) build/bin/$(archive)
endef

$(eval $(call EXPAND_DEPLOY))

stats:
	@echo
	@echo '------------------------------'
	@echo 'Compiler and standard library '
	@echo '------------------------------'
	@echo
	@cloc --read-lang-def=pony.cloc src packages
	@echo
	@echo '------------------------------'
	@echo 'Test suite:'
	@echo '------------------------------'
	@echo
	@cloc --read-lang-def=pony.cloc test

clean:
	@rm -rf $(PONY_BUILD_DIR)
	@rm -rf $(package)
	@rm -rf build/bin
	@rm -rf stdlib-docs
	@rm -f src/common/dtrace_probes.h
	-@rmdir build 2>/dev/null ||:
	@echo 'Repository cleaned ($(PONY_BUILD_DIR)).'

help:
	@echo 'Usage: make [config=name] [arch=name] [use=opt,...] [target]'
	@echo
	@echo 'CONFIGURATIONS:'
	@echo '  debug'
	@echo '  release (default)'
	@echo
	@echo 'ARCHITECTURE:'
	@echo '  native (default)'
	@echo '  [any compiler supported architecture]'
	@echo
	@echo 'Compile time default options:'
	@echo '  default_pic=true     Make --pic the default'
	@echo '  default_ssl=Name     Make Name the default ssl version'
	@echo '                       where Name is one of:'
	@echo '                         openssl_0.9.0'
	@echo '                         openssl_1.1.0'
	@echo
	@echo 'USE OPTIONS:'
	@echo '   valgrind'
	@echo '   pooltrack'
	@echo '   dtrace'
	@echo '   actor_continuations'
	@echo '   coverage'
	@echo '   llvm_link_static'
	@echo '   scheduler_scaling_pthreads'
	@echo
	@echo 'TARGETS:'
	@echo '  libponyc               Pony compiler library'
	@echo '  libponyrt              Pony runtime'
	@echo '  libponyrt-pic          Pony runtime -fpic'
	@echo '  libponyc.tests         Test suite for libponyc'
	@echo '  libponyrt.tests        Test suite for libponyrt'
	@echo '  libponyc.benchmarks    Benchmark suite for libponyc'
	@echo '  libponyrt.benchmarks   Benchmark suite for libponyrt'
	@echo '  ponyc                  Pony compiler executable'
	@echo
	@echo '  all                    Build all of the above (default)'
	@echo '  test                   Run test suite'
	@echo '  benchmark              Build and run benchmark suite'
	@echo '  install                Install ponyc'
	@echo '  install-libponyrt      Install libponyrt only (for cross'
	@echo '                         linking)'
	@echo '  install-libponyrt-pic  Install libponyrt-pic only (for cross'
	@echo '                         linking)'
	@echo '  uninstall              Remove all versions of ponyc'
	@echo '  stats                  Print Pony cloc statistics'
	@echo '  clean                  Delete all build files'
	@echo
