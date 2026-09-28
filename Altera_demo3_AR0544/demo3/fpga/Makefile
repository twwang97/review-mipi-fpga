# Simulation / lint helpers. Quartus build is driven from demo3.qsf.
RTL   := $(wildcard rtl/*.v)
IP    := $(wildcard ip/*.v)
INC   := -Irtl
IV    := iverilog -g2001 $(INC)

.PHONY: all lint tb clean

all: lint tb

lint:
	$(IV) -Wall -o build/demo3.out -s demo3_top $(RTL) $(IP)
	@echo "lint: demo3_top elaborated"

tb:
	$(IV) -o build/algos.out -s tb_csi2_algos tb/tb_csi2_algos.v
	vvp build/algos.out

clean:
	rm -rf build/*.out
