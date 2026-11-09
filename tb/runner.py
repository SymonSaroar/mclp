"""Shared cocotb runner for the unit tests: Icarus Verilog, SystemVerilog 2012, build in build/tb/<top>."""
import os
import shutil
from pathlib import Path

from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parents[1]


def run(top, sources, test_file, parameters=None, files=()):
    """Build `sources` (repo-relative), copy `files` (e.g. $readmemh images) into the run dir, run test_file."""
    test_file = Path(test_file)
    build = ROOT / "build" / "tb" / top
    build.mkdir(parents=True, exist_ok=True)
    for f in files:
        shutil.copy(ROOT / f, build)
    sim = get_runner("icarus")
    sim.build(sources=[ROOT / s for s in sources], hdl_toplevel=top, parameters=parameters or {},
              build_args=["-g2012"], build_dir=build, always=True, timescale=("1ns", "1ps"))
    path = os.pathsep.join([str(test_file.parent), str(ROOT / "tb"), os.environ.get("PYTHONPATH", "")])
    sim.test(hdl_toplevel=top, test_module=test_file.stem, build_dir=build, test_dir=build,
             timescale=("1ns", "1ps"), extra_env={"PYTHONPATH": path})
