CC ?= cc
CFLAGS = -std=c11 -O2 -Wall -Wextra -Werror -fsanitize=address,undefined -g -I../../Sources/CMixer/include

test: test_mixer
	./test_mixer

test_mixer: test_mixer.c ../../Sources/CMixer/cmixer.c ../../Sources/CMixer/include/cmixer.h
	$(CC) $(CFLAGS) -D_POSIX_C_SOURCE=200809L -o $@ test_mixer.c ../../Sources/CMixer/cmixer.c -lm -lpthread

clean:
	rm -f test_mixer

.PHONY: test clean
