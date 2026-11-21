"""Co-simulation of mclp against the mclp_core RTL (Icarus, cocotb).

mclp's --sim backend sends every register access over TCP; this testbench runs mclp_core with eight
AD7190 models, performs the accesses on the PS stand-in's AXI4-Lite port, advances simulation time on
request and returns raw records for mclp's AXI DMA model. Simulation time stands still between requests.
"""
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "build" / "cosim"
CLIENT = BUILD / ("mclp.exe" if os.name == "nt" else "mclp")
SAMPLES = [400_000 + 20_000 * k for k in range(8)]

# ----------------------------------------------------------------------------- cocotb side
try:
    import cocotb
    from cocotb.simtime import get_sim_time
    from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer, ValueChange
except ImportError:                                   # outside cocotb
    cocotb = None


def ms():
    return get_sim_time("us") / 1000.0


def log(text):
    print(f"[{ms():10.3f} ms] RTL  {text}", flush=True)


class Bench:
    def __init__(self, dut):
        self.top = dut
        self.ps = dut.dut
        self.clk = self.ps.clk
        self.records = 0

    def set_inputs(self, samples=None, open_wire=None, no_ref=None):
        if samples is not None:
            self.top.samples.value = sum((s & 0xFFFFFF) << (24 * k) for k, s in enumerate(samples))
        if open_wire is not None:
            self.top.open_wire.value = open_wire
        if no_ref is not None:
            self.top.no_ref.value = no_ref

    async def write(self, addr, data):
        ps = self.ps
        await FallingEdge(self.clk)
        ps.awaddr.value, ps.wdata.value, ps.awvalid.value, ps.wvalid.value = addr, data, 1, 1
        while True:
            await RisingEdge(self.clk)
            if ps.M_AXI_REGS_awready.value and ps.M_AXI_REGS_wready.value:
                break
        await FallingEdge(self.clk)
        ps.awvalid.value, ps.wvalid.value, ps.bready.value = 0, 0, 1
        while True:
            await RisingEdge(self.clk)
            if ps.M_AXI_REGS_bvalid.value:
                break
        await FallingEdge(self.clk)
        ps.bready.value = 0

    async def read(self, addr):
        ps = self.ps
        await FallingEdge(self.clk)
        ps.araddr.value, ps.arvalid.value = addr, 1
        while True:
            await RisingEdge(self.clk)
            if ps.M_AXI_REGS_arready.value:
                break
        await FallingEdge(self.clk)
        ps.arvalid.value, ps.rready.value = 0, 1
        while True:
            await RisingEdge(self.clk)
            if ps.M_AXI_REGS_rvalid.value:
                v = ps.M_AXI_REGS_rdata.value
                if not v.is_resolvable:
                    r = self.top.dut.mclp_core_0.mclp_registers_0
                    log(f"X read at 0x{addr:08X}: rdata={v} irq_status={r.reg_irq_status.value} "
                        f"events={r.irq_events.value} levels={r.dsp_levels_axi.value} seq_busy={r.seq_busy_axi.value} status_q={r.status_q.value}")
                    raise AssertionError("read returned X")
                data = int(v)
                break
        await FallingEdge(self.clk)
        ps.rready.value = 0
        return data

    def drain(self):
        """Beats the raw sink collected since the last call, as 'B hi lo last' lines."""
        n = int(self.ps.raw_n.value)
        lines = []
        for i in range(n):
            d = int(self.ps.raw_data[i].value)
            last = int(self.ps.raw_last[i].value)
            lines.append(f"B {d >> 32:08X} {d & 0xFFFFFFFF:08X} {last}\n")
            self.records += last
        if n:
            self.ps.raw_n.value = 0
        return "".join(lines)

    async def serve(self, conn, log_writes=True):
        """One client connection; returns False when the client asked the server to stop."""
        f = conn.makefile("rb")
        before = self.records
        try:
            while True:
                req = f.readline().decode().split()
                if not req or req[0] == "Q":
                    return True
                if req[0] == "X":
                    return False
                value = ""
                if req[0] == "R":
                    value = f"{await self.read(int(req[1], 16)):08X}"
                elif req[0] == "W":
                    a, v = int(req[1], 16), int(req[2], 16)
                    if log_writes:
                        log(f"AXI write 0x{a:08X} <- 0x{v:08X}")
                    await self.write(a, v)
                elif req[0] == "T":
                    value = f"{int(get_sim_time('us')):X}"
                elif req[0] == "D":
                    await Timer(int(req[1]), "us")
                else:
                    conn.sendall(f"E unknown request {req[0]}\n".encode())
                    continue
                await FallingEdge(self.clk)
                conn.sendall((self.drain() + f"OK {value}\n").encode())
        finally:
            if self.records != before:
                log(f"{self.records - before} raw records went to mclp's DMA model")
            conn.close()

    def monitor(self):
        top = self.top.dut.mclp_core_0

        async def watch(sig, show):
            last = None
            while True:                               # report settled values only: Icarus evaluates
                await ValueChange(sig)                # combinational nets in steps, which can glitch
                await ReadOnly()
                if str(sig.value) != last:
                    last = str(sig.value)
                    show(sig.value)

        def faults(v):
            v = int(v)
            set_ = [f"ch{c}:{','.join(n for b, n in enumerate(('ERR', 'NOREF', 'PARITY', 'STALE', 'MISMATCH')) if v >> (5 * c + b) & 1)}"
                    for c in range(8) if v >> (5 * c) & 31]
            log("fault flags " + (" ".join(set_) if set_ else "cleared"))

        adc0 = self.top.g_adc[0].u_adc
        modes = {0: "continuous", 1: "single", 2: "idle", 3: "power-down", 4: "internal zero-scale calibration",
                 5: "internal full-scale calibration", 6: "system zero-scale", 7: "system full-scale"}
        cocotb.start_soon(watch(top.mclp_registers_0.seq_busy_axi,
                                lambda v: log("sequencer " + ("running a list" if int(v) else "done: list reached STREAM or END"))))
        cocotb.start_soon(watch(top.irq, lambda v: log("interrupt line " + ("high" if int(v) else "low"))))
        cocotb.start_soon(watch(top.spi_loopback, lambda v: log("front end reads DOUT from " + ("the PL loopback emulator" if int(v) else "the AD7190 models"))))
        cocotb.start_soon(watch(top.dsp_faults, faults))
        cocotb.start_soon(watch(top.dsp_stable, lambda v: log("weight " + ("stable" if int(v) else "in motion"))))
        cocotb.start_soon(watch(top.dsp_overload, lambda v: log("overload " + ("set" if int(v) else "cleared"))))
        cocotb.start_soon(watch(adc0.conf, lambda v: log(f"AD7190 #0 configuration register <- 0x{int(v):06X}"
                                                         f"{' (burnout currents on)' if int(v) & 0x80 else ''}"
                                                         f"{' (AIN2-AIN2 internal short)' if int(v) & 0x800 else ''}")))
        cocotb.start_soon(watch(adc0.mode, lambda v: log(f"AD7190 #0 mode register <- 0x{int(v):06X} ({modes[int(v) >> 21 & 7]})")))
        cocotb.start_soon(watch(self.top.sync_n, lambda v: log("SYNC low: all AD7190 restart their filters") if not int(v) else None))

    async def start(self):
        self.set_inputs(samples=SAMPLES, open_wire=0, no_ref=0)
        self.monitor()
        log(f"ADC inputs: {SAMPLES}")
        await Timer(3, "ms")                          # power-up: MMCM lock, init list, first frames
        self.drain()
        log("platform up; power-up init list done")


def listen(host, port):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen(1)
    return srv


if cocotb:
    @cocotb.test()
    async def serve(dut):
        """Interactive: serve mclp clients until one sends X (or the simulation is stopped)."""
        bench = Bench(dut)
        await bench.start()
        host, port = os.environ.get("COSIM_HOST", "127.0.0.1"), int(os.environ.get("COSIM_PORT", "5555"))
        srv = listen(host, port)
        print(f"\nco-simulation server listening on {host}:{port}\n"
              f"  {CLIENT} -t --sim {'127.0.0.1' if host == '0.0.0.0' else host}:{port} [command]\n", flush=True)
        while True:
            conn, peer = srv.accept()
            log(f"client {peer[0]} connected")
            if not await bench.serve(conn):
                break
            log("client disconnected")
        srv.close()

    async def client(bench, srv, port, *args, expect_rc=0):
        """Runs one mclp command; its output streams live (between the RTL log lines) and is returned."""
        print(f"\n$ mclp -t {' '.join(args)}", flush=True)
        p = subprocess.Popen([str(CLIENT), "-t", "--sim", f"127.0.0.1:{port}", *args], stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, cwd=BUILD, text=True, bufsize=1)
        lines = []

        def pump():
            for line in p.stdout:
                print(line, end="", flush=True)
                lines.append(line)

        t = threading.Thread(target=pump, daemon=True)
        t.start()
        conn, _ = srv.accept()
        await bench.serve(conn)
        rc = p.wait(timeout=60)
        t.join(timeout=10)
        assert rc == expect_rc, f"mclp {' '.join(args)}: exit {rc}, expected {expect_rc}"
        return "".join(lines)

    @cocotb.test()
    async def flows(dut):
        """mclp commands against the RTL, with checks on their output and trace."""
        bench = Bench(dut)
        await bench.start()
        srv = listen("127.0.0.1", 0)
        srv.settimeout(60)
        port = srv.getsockname()[1]
        (BUILD / "mclp-sim.cal").unlink(missing_ok=True)

        out = await client(bench, srv, port, "info")
        assert "backend co-simulation" in out

        out = await client(bench, srv, port, "status")
        assert "FPGA ID 4D4C0308, MMCM locked, sequencer streaming" in out
        assert re.search(r"RD STATUS +-> 0x00000001 +locked", out), "trace decodes STATUS"

        out = await client(bench, srv, port, "init")
        assert "(8 of 8 answer as AD7190)" in out
        assert "devmem 0x43C00004 32 0x00000009" in out, "trace shows CTRL.seq_start as a devmem write"
        assert "cmd XFER ntx=32 nrx=0" in out, "trace decodes sequencer commands"

        out = await client(bench, srv, port, "raw", "0", "16")
        rows = [list(map(int, l.split(",")[3:])) for l in out.splitlines() if re.match(r"^\d+,\d+,", l)]
        assert len(rows) == 16 and all(r == SAMPLES for r in rows), "tap 0 records carry the ADC codes"

        out = await client(bench, srv, port, "raw", "3", "4")
        rows = [list(map(int, l.split(",")[3:])) for l in out.splitlines() if re.match(r"^\d+,\d+,", l)]
        assert len(rows) == 4 and all(r == [256 * s for s in SAMPLES] for r in rows), \
            "tap 3 = 256 x code x gain 1 x trim 1"

        out = await client(bench, srv, port, "bist")
        assert "BIST PASSED" in out
        assert re.search(r"WR CTRL +<- 0x0000000[3-7] +enable loopback", out), "trace shows CTRL.loopback"
        assert "inject_ERR ch=4" in out

        bench.set_inputs(open_wire=1 << 6, no_ref=1 << 1)
        log("ADC inputs: open wire on channel 6, missing reference on channel 1")
        out = await client(bench, srv, port, "selftest", expect_rc=1)
        table = {int(l.split()[0]): l for l in out.splitlines() if re.match(r"^ \d  ", l)}
        assert "OPEN" in table[6] and "FAIL" in table[6], table[6]
        assert "MISSING" in table[1] and "FAIL" in table[1], table[1]
        assert all("PASS" in table[c] for c in (0, 2, 3, 4, 5, 7))
        bench.set_inputs(open_wire=0, no_ref=0)

        out = await client(bench, srv, port, "faults", "clear")
        assert all(f"ch{c}: -" in out for c in range(8))
        srv.close()
        log("all mclp flows passed")


# ----------------------------------------------------------------------------- build and run
def find_cc():
    """A native compiler for the client. On Windows that must be MinGW: a Cygwin gcc builds against
    cygwin1.dll, and name lookup in that build fails outside a Cygwin shell."""
    cands = [os.environ.get("COSIM_CC"), "C:/Xilinx/2025.1/tps/mingw/10.0.0/win64.o/nt/bin/gcc.exe",
             shutil.which("gcc")]
    for cc in filter(None, cands):
        if not Path(cc).exists():
            continue
        env = dict(os.environ, PATH=str(Path(cc).parent) + os.pathsep + os.environ.get("PATH", ""))
        target = subprocess.run([cc, "-dumpmachine"], capture_output=True, text=True, env=env).stdout
        if os.name != "nt" or "mingw" in target:
            return cc, env
    sys.exit("no MinGW gcc found for the mclp client; set COSIM_CC to one")


def build_client():
    BUILD.mkdir(parents=True, exist_ok=True)
    cc, env = find_cc()
    common = ROOT / "sw" / "common"
    cmd = [cc, "-O2", "-std=gnu11", "-Wall", "-Wextra", f"-I{common}", "-o", str(CLIENT),
           str(ROOT / "sw/linux/mclp/main.c"), str(ROOT / "sw/linux/mclp/backend.c"), *(str(common / f) for f in ("console.c", "mclp_ops.c", "calib.c")), "-lm"]
    if os.name == "nt":
        cmd[1:1] = ["-D_WIN32_WINNT=0x0601"]
        cmd.append("-lws2_32")
    subprocess.run(cmd, check=True, env=env)


def run(testcase, extra_env=None, waves=False):
    from cocotb_tools.runner import get_runner
    build_client()
    for f in ("fir64.mem", "seq_init.mem", "unity64.mem"):
        shutil.copy(ROOT / "coeff" / f, BUILD)
    sources = sorted((ROOT / "rtl").glob("*.sv")) + [ROOT / "tb/system" / f for f in (
        "mclp_top_wrapper_stub.sv", "ad7190_model.sv")] + \
        [ROOT / "tb/common/xpm_models.sv", ROOT / "tb/cosim/cosim_top.sv"]
    sim = get_runner("icarus")
    sim.build(sources=sources, hdl_toplevel="cosim_top", build_args=["-g2012"], build_dir=BUILD, always=True,
              timescale=("1ns", "1ps"))
    sim.test(hdl_toplevel="cosim_top", test_module="test_cosim", testcase=testcase, build_dir=BUILD, test_dir=BUILD,
             timescale=("1ns", "1ps"), extra_env={"PYTHONPATH": str(Path(__file__).resolve().parent), **(extra_env or {})},
             plusargs=["+waves", "-fst"] if waves else [])


def test_cosim():
    run("flows")


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["serve"]:
        opt = {a: args[i + 1] for i, a in enumerate(args[:-1]) if a in ("--host", "--port")}
        run("serve", {"COSIM_HOST": opt.get("--host", "127.0.0.1"), "COSIM_PORT": opt.get("--port", "5555")},
            waves="--waves" in args)
    else:
        test_cosim()

