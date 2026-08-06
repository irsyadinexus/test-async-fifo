#include "Vtb_async_fifo.h"
#include "verilated.h"

int main(int argc, char** argv) {
  VerilatedContext context;
  context.commandArgs(argc, argv);
  Vtb_async_fifo top{&context};
  while (!context.gotFinish()) {
    top.eval();
    if (!top.eventsPending()) break;
    context.time(top.nextTimeSlot());
  }
  top.final();
  context.coveragep()->write("coverage.dat");
  return 0;
}
