# Built by elixir_make (mix compile). Standalone: `make` from the project root.
#
#   PARAKEET_DIR      parakeet.cpp checkout (headers in include/)
#   PARAKEET_LIB_DIR  directory holding libparakeet.so
#   ERTS_INCLUDE_DIR  erl_nif.h directory (set by elixir_make)

PARAKEET_DIR ?= ../parakeet.cpp
PARAKEET_LIB_DIR ?= $(PARAKEET_DIR)/build-shared
ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval 'io:format("~s", [filename:join([code:root_dir(), "erts-" ++ erlang:system_info(version), "include"])]), halt().')

# The rpath must be absolute: the NIF is loaded from whatever cwd the VM has.
PARAKEET_LIB_DIR_ABS := $(abspath $(PARAKEET_LIB_DIR))

CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter -fPIC
CFLAGS += -std=gnu11

PRIV_DIR := priv
TARGET := $(PRIV_DIR)/parakeet_diar_nif.so
SRC := c_src/parakeet_diar_nif.c

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRC)
	mkdir -p $(PRIV_DIR)
	$(CC) $(CFLAGS) -shared \
		-I$(PARAKEET_DIR)/include -I$(ERTS_INCLUDE_DIR) \
		$(SRC) -o $@ \
		-L$(PARAKEET_LIB_DIR_ABS) -lparakeet -Wl,-rpath,$(PARAKEET_LIB_DIR_ABS)

clean:
	rm -f $(TARGET)
