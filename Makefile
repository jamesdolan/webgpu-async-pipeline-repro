.PHONY: run

run: .build/native-metal
	@./.build/native-metal

.build/native-metal: native-metal.mm Makefile
	@mkdir -p $(@D)
	@xcrun clang++ -std=c++20 -fobjc-arc -O2 -Wall -Wextra -framework Foundation -framework Metal $< -o $@
