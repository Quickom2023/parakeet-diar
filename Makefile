# Built by elixir_make (mix compile). Standalone: `make` from the project root.
#
#   PARAKEET_DIR      parakeet.cpp checkout (headers in include/)
#   PARAKEET_LIB_DIR  directory holding libparakeet.so (the CPU build)
#   PARAKEET_GGML_DIR directory holding the libggml*.so.0 that libparakeet needs
#   ERTS_INCLUDE_DIR  erl_nif.h directory (set by elixir_make)
#
# The NIF links -lparakeet (NEEDED libparakeet.so) and finds it through
# RUNPATH $ORIGIN/lib. The bundled copies in priv/lib are what a machine without
# a parakeet.cpp build uses. LD_LIBRARY_PATH still wins over RUNPATH, so a GPU
# box can point it at a CUDA build of the same commit.

PARAKEET_DIR ?= ../parakeet.cpp
PARAKEET_LIB_DIR ?= $(PARAKEET_DIR)/build-shared
PARAKEET_GGML_DIR ?= $(PARAKEET_LIB_DIR)/third_party/ggml/src
ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval 'io:format("~s", [filename:join([code:root_dir(), "erts-" ++ erlang:system_info(version), "include"])]), halt().')

# The link-time search path is absolute; the runtime search path is relative to the NIF.
PARAKEET_LIB_DIR_ABS := $(abspath $(PARAKEET_LIB_DIR))

CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter -fPIC
CFLAGS += -std=gnu11

# Under mix, elixir_make sets MIX_APP_PATH: artifacts go to its priv, which is
# what precompiled archives pack. Standalone `make` uses ./priv.
PRIV_DIR := $(if $(MIX_APP_PATH),$(MIX_APP_PATH)/priv,priv)
LIB_DIR := $(PRIV_DIR)/lib
TARGET := $(PRIV_DIR)/parakeet_diar_nif.so
SRC := c_src/parakeet_diar_nif.c

GGML_LIBS := libggml.so.0 libggml-cpu.so.0 libggml-base.so.0
BUNDLED := $(LIB_DIR)/libparakeet.so $(addprefix $(LIB_DIR)/,$(GGML_LIBS))

# Copies a library in under its soname (cp -L resolves symlinks) and gives it
# RUNPATH $ORIGIN so it finds its ggml siblings in the same directory.
define bundle_lib
	@command -v patchelf >/dev/null 2>&1 || { echo "parakeet_diar: patchelf is required to bundle libparakeet (sudo apt-get install patchelf)" >&2; exit 1; }
	cp -L $(1) $(2)
	patchelf --set-rpath '$$ORIGIN' $(2)
endef

.PHONY: all clean

all: $(TARGET) $(BUNDLED)

$(TARGET): $(SRC)
	mkdir -p $(PRIV_DIR)
	$(CC) $(CFLAGS) -shared \
		-I$(PARAKEET_DIR)/include -I$(ERTS_INCLUDE_DIR) \
		$(SRC) -o $@ \
		-L$(PARAKEET_LIB_DIR_ABS) -lparakeet -Wl,-rpath,'$$ORIGIN/lib'

$(LIB_DIR):
	mkdir -p $(LIB_DIR)

$(LIB_DIR)/libparakeet.so: $(PARAKEET_LIB_DIR)/libparakeet.so | $(LIB_DIR)
	$(call bundle_lib,$<,$@)

$(addprefix $(LIB_DIR)/,$(GGML_LIBS)): $(LIB_DIR)/%: $(PARAKEET_GGML_DIR)/% | $(LIB_DIR)
	$(call bundle_lib,$<,$@)

clean:
	rm -f $(TARGET)
	rm -rf $(LIB_DIR)
