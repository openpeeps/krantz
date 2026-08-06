#!/usr/bin/env python3
"""krantz interactive test suite (pty-based, fully hermetic).

Each test spawns krantz in a fresh pseudo-terminal with an isolated temp
workspace + HOME, drives it with real keystrokes, and asserts on the output.

Run directly:
    python3 tests/test_interactive.py [filter]
Via nimble:
    nimble test
"""

import fcntl
import os
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

PROMPT = b"\xe2\x80\xba"  # U+203A '›' prompt marker
TAB = b"\x09"
CR = b"\r"
ESC = b"\x1b"
BS = b"\x7f"
CTRL_C = b"\x03"

KRANTZ = os.environ.get("KRANTZ",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "krantz"))
SYSTEM_PATH = os.environ.get("KRANTZ_TEST_PATH", "/usr/bin:/bin")


class Fixture:
    """Per-test isolated workspace + HOME + fake executable bin."""

    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="krantz-test-")
        self.home = os.path.join(self.root, "home")
        self.work = os.path.join(self.root, "work")
        self.bin = os.path.join(self.root, "bin")
        os.makedirs(self.home)
        os.makedirs(self.work)
        os.makedirs(self.bin)
        os.makedirs(os.path.join(self.home, ".Trash"))
        os.makedirs(os.path.join(self.home, "Creative Cloud Files"))

        # fake executables -> deterministic command completion
        for name in ("gimp", "gitx", "grep2", "nan2"):
            p = os.path.join(self.bin, name)
            open(p, "w").close()
            os.chmod(p, 0o755)

        # workspace fixtures
        for f in ("alpha.txt", "beta.txt", "gamma.log"):
            open(os.path.join(self.work, f), "w").close()
        open(os.path.join(self.work, ".hidden"), "w").close()
        with open(os.path.join(self.work, "krantz alias"), "w") as fh:
            fh.write("HELLO")
        for d in ("deep/path/here", "My Folder", "src", "subdir"):
            os.makedirs(os.path.join(self.work, d))

        self.path = self.bin + ":" + SYSTEM_PATH

    def cleanup(self):
        shutil.rmtree(self.root, ignore_errors=True)


class Shell:
    """A krantz REPL session running on a pty."""

    def __init__(self, fix, path=None):
        self.fix = fix
        self.path = path or fix.path
        # krantz's loadShellEnv() runs a login shell that sources ~/.zshrc and
        # overwrites PATH, so pin PATH there to keep tests hermetic.
        with open(os.path.join(fix.home, ".zshrc"), "w") as fh:
            fh.write("export PATH='%s'\n" % self.path)
        self.pid, self.fd = pty_fork(self.path, fix.work, fix.home)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 80, 0, 0))
        self.out = bytearray()

    def pump(self, t=0.4):
        end = time.time() + t
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if r:
                try:
                    d = os.read(self.fd, 4096)
                except OSError:
                    return
                if not d:
                    return
                self.out.extend(d)

    def send(self, data, t=0.5):
        os.write(self.fd, data)
        self.pump(t)

    def wait_prompt(self, base=None, timeout=8.0):
        if base is None:
            base = 0
        end = time.time() + timeout
        while time.time() < end:
            if PROMPT in bytes(self.out[base:]):
                return True
            self.pump(0.1)
        return False

    def segment(self, base):
        return bytes(self.out[base:])

    def run_cmd(self, cmd, wait=5.0):
        base = len(self.out)
        self.send(cmd + CR, t=0.3)
        self.wait_prompt(base, timeout=wait)
        return bytes(self.out[base:])

    def close(self):
        try:
            os.write(self.fd, b"\x04")
            self.pump(0.3)
        except OSError:
            pass
        try:
            os.close(self.fd)
        except OSError:
            pass
        try:
            os.kill(self.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def pty_fork(path, cwd, home):
    pid, fd = os.forkpty()
    if pid == 0:
        os.chdir(cwd)
        os.environ["TERM"] = "xterm-256color"
        os.environ["HOME"] = home
        os.environ["PATH"] = path
        os.execv(KRANTZ, [KRANTZ])
        os._exit(127)
    return pid, fd


# --------------------------------------------------------------------------- #
# cases
# --------------------------------------------------------------------------- #

def t_completion_cycle(fix):
    sh = Shell(fix)
    if not sh.wait_prompt():
        return [("prompt", False)]
    r = []

    base = len(sh.out)
    sh.send(b"cat " + TAB, t=0.4)
    r.append(("first candidate = alpha.txt", b"cat alpha.txt " in sh.segment(base)))
    r.append(("dotfiles hidden in listing", b".hidden" not in sh.segment(base)))

    base = len(sh.out)
    sh.send(TAB, t=0.3)
    r.append(("second candidate = beta.txt", b"cat beta.txt " in sh.segment(base)))

    # 8 candidates: alpha, beta, deep/, gamma, krantz alias, My Folder/, src/, subdir/
    base = len(sh.out)
    for _ in range(7):
        sh.send(TAB, t=0.25)
    r.append(("wraps back to alpha.txt", b"cat alpha.txt " in sh.segment(base)))

    sh.close()
    return r


def t_completion_single(fix):
    sh = Shell(fix)
    if not sh.wait_prompt():
        return [("prompt", False)]
    base = len(sh.out)
    sh.send(b"cat a" + TAB, t=0.4)
    got = sh.segment(base)
    sh.close()
    return [("cat a<TAB> inserts alpha.txt", b"cat alpha.txt " in got)]


def t_completion_cd(fix):
    sh = Shell(fix)
    if not sh.wait_prompt():
        return [("prompt", False)]
    r = []

    base = len(sh.out)
    sh.send(b"cd " + TAB, t=0.4)
    got = sh.segment(base)
    r.append(("cd lists dirs only (deep/ first)", b"cd deep/" in got))
    r.append(("cd does not list files", b"alpha.txt" not in got))

    base = len(sh.out)
    sh.send(ESC, t=0.3)
    base = len(sh.out)
    sh.send(b"cd s" + TAB, t=0.4)
    r.append(("cd s<TAB> -> src/", b"cd src/" in sh.segment(base)))

    sh.close()
    return r


def t_completion_command(fix):
    bin_only = fix.bin
    r = []

    sh = Shell(fix, path=bin_only)
    if not sh.wait_prompt():
        return [("prompt", False)]
    base = len(sh.out)
    sh.send(b"ech" + TAB, t=0.4)
    r.append(("builtin: ech<TAB> -> echo", b"echo" in sh.segment(base)))
    sh.close()

    sh = Shell(fix, path=bin_only)
    if not sh.wait_prompt():
        return [("prompt2", False)]
    base = len(sh.out)
    sh.send(b"g" + TAB, t=0.4)
    r.append(("PATH: g<TAB> -> gimp", b"gimp" in sh.segment(base)))
    base = len(sh.out)
    sh.send(TAB, t=0.3)
    r.append(("PATH: cycle -> gitx", b"gitx" in sh.segment(base)))
    sh.close()

    sh = Shell(fix, path=bin_only)
    if not sh.wait_prompt():
        return [("prompt3", False)]
    base = len(sh.out)
    sh.send(b"nan" + TAB, t=0.4)
    r.append(("PATH: nan<TAB> -> nan2", b"nan2" in sh.segment(base)))
    sh.close()
    return r


def t_completion_path(fix):
    sh = Shell(fix)
    if not sh.wait_prompt():
        return [("prompt", False)]
    r = []
    base = len(sh.out)
    sh.send(b"cat deep/" + TAB, t=0.4)
    r.append(("cat deep/<TAB> -> deep/path/", b"cat deep/path/" in sh.segment(base)))
    sh.close()
    return r


def t_completion_dotfile(fix):
    sh = Shell(fix)
    if not sh.wait_prompt():
        return [("prompt", False)]
    base = len(sh.out)
    sh.send(b"cat .h" + TAB, t=0.4)
    got = sh.segment(base)
    sh.close()
    return [("cat .h<TAB> reveals .hidden", b"cat .hidden " in got)]


def t_completion_tilde(fix):
    sh = Shell(fix)
    if not sh.wait_prompt():
        return [("prompt", False)]
    r = []

    base = len(sh.out)
    sh.send(b"cd ~/Crea" + TAB, t=0.5)
    seg1 = sh.segment(base)
    r.append(("tilde completes", b"cd ~/Creative\\ Cloud\\ Files/" in seg1))
    r.append(("tilde not escaped", b"cd \\~/" not in seg1))

    base = len(sh.out)
    sh.send(BS * 5 + TAB, t=0.5)  # drop "Files", re-tab
    seg2 = sh.segment(base)
    r.append(("recompletes after backspace", b"~/Creative\\ Cloud\\ Files/" in seg2))
    r.append(("no doubled backslashes", b"\\\\" not in seg2))

    # keep only "Creative", repeated tabs must not cascade backslashes
    base = len(sh.out)
    sh.send(BS * 15 + TAB, t=0.5)
    seg3 = sh.segment(base)
    r.append(("no \\\\~ cascade", b"\\\\~" not in seg3))
    r.append(("keeps single backslash", b"~/Creative\\ Cloud\\ Files/" in seg3))

    sh.close()
    return r


def t_completion_esc(fix):
    sh = Shell(fix)
    if not sh.wait_prompt():
        return [("prompt", False)]
    sh.send(b"cat " + TAB, t=0.4)
    base = len(sh.out)
    sh.send(ESC, t=0.3)
    seg = sh.segment(base)
    sh.close()
    return [("ESC cancels (no candidate)", b"alpha" not in seg),
            ("ESC keeps command line", b"cat " in seg)]


def t_completion_space_accept(fix):
    sh = Shell(fix)
    if not sh.wait_prompt():
        return [("prompt", False)]
    sh.send(b"cat " + TAB, t=0.4)
    base = len(sh.out)
    sh.send(b" ", t=0.3)
    seg = sh.segment(base)
    sh.close()
    return [("space keeps single trailing space", b"cat alpha.txt " in seg),
            ("no double space", b"cat alpha.txt  " not in seg)]


def t_completion_space_execute(fix):
    sh = Shell(fix)
    if not sh.wait_prompt():
        return [("prompt", False)]
    # alpha(0) -> beta(1) -> deep/(2) -> gamma(3) -> krantz alias(4)
    base = len(sh.out)
    sh.send(b"cat " + TAB, t=0.4)
    for _ in range(4):
        sh.send(TAB, t=0.25)
    seg_comp = sh.segment(base)

    base = len(sh.out)
    sh.send(CR, t=0.3)
    sh.wait_prompt(base, timeout=5.0)
    seg_run = sh.segment(base)

    sh.close()
    return [("escaped candidate inserted", b"cat krantz\\ alias " in seg_comp),
            ("command runs and prints content", b"HELLO" in seg_run)]


def t_path_navigation(fix):
    sh = Shell(fix)
    if not sh.wait_prompt():
        return [("prompt", False)]
    r = []

    sh.run_cmd(b"cd deep/path/here")
    seg = sh.run_cmd(b"pwd")
    r.append(("cd deep/path/here", (fix.work + "/deep/path/here").encode() in seg))

    seg = sh.run_cmd(b"cd ../../")
    seg = sh.run_cmd(b"pwd")
    r.append(("cd ../../ (two levels)", (fix.work + "/deep").encode() in seg))

    seg = sh.run_cmd(b"cd ..")
    seg = sh.run_cmd(b"pwd")
    r.append(("cd .. back to work", fix.work.encode() in seg))

    seg = sh.run_cmd(b"cd subdir")
    seg = sh.run_cmd(b"pwd")
    r.append(("cd subdir", (fix.work + "/subdir").encode() in seg))

    seg = sh.run_cmd(b"cd -")
    seg = sh.run_cmd(b"pwd")
    r.append(("cd - goes back", fix.work.encode() in seg))

    seg = sh.run_cmd(b"cd")
    seg = sh.run_cmd(b"pwd")
    r.append(("cd goes home", fix.home.encode() in seg))

    sh.close()
    return r


def t_pipes_redirection(fix):
    sh = Shell(fix)
    if not sh.wait_prompt():
        return [("prompt", False)]
    r = []

    seg = sh.run_cmd(b"echo hi | tr a-z A-Z")
    r.append(("pipe echo|tr", b"HI" in seg))

    sh.run_cmd(b"echo hello > out.txt")
    seg = sh.run_cmd(b"cat out.txt")
    r.append(("> write", b"hello" in seg))

    sh.run_cmd(b"echo second >> out.txt")
    seg = sh.run_cmd(b"cat out.txt")
    r.append((">> append", b"hello" in seg and b"second" in seg))

    seg = sh.run_cmd(b"cat < out.txt")
    r.append(("< input", b"hello" in seg))

    sh.run_cmd(b"ls nope_xyz_123 2> err.txt")
    seg = sh.run_cmd(b"cat err.txt")
    r.append(("2> stderr redirect", b"nope_xyz_123" in seg))

    seg = sh.run_cmd(b"true && echo yes")
    r.append(("&&", b"yes" in seg))

    seg = sh.run_cmd(b"false || echo ok")
    r.append(("||", b"ok" in seg))

    sh.close()
    return r


def t_variables(fix):
    sh = Shell(fix)
    if not sh.wait_prompt():
        return [("prompt", False)]
    r = []

    seg = sh.run_cmd(b"echo $HOME")
    r.append(("env var $HOME expansion", fix.home.encode() in seg))

    seg = sh.run_cmd(b"echo ${HOME}")
    r.append(("env var ${HOME} expansion", fix.home.encode() in seg))

    seg = sh.run_cmd(b"export")
    r.append(("export prints environment", b"PATH=" in seg))

    seg = sh.run_cmd(b"echo one")
    seg = sh.run_cmd(b"history")
    r.append(("history records commands", b"echo one" in seg))

    sh.close()
    return r


def t_trash(fix):
    sh = Shell(fix)
    if not sh.wait_prompt():
        return [("prompt", False)]
    note = os.path.join(fix.work, "note.txt")
    with open(note, "w") as fh:
        fh.write("keep me")
    sh.run_cmd(b"trash note.txt")
    sh.close()
    moved = os.path.join(fix.home, ".Trash", "note.txt")
    return [("trash moves to ~/.Trash", os.path.exists(moved)),
            ("trash removes from workdir", not os.path.exists(note))]


def t_policy(fix):
    sh = Shell(fix)
    if not sh.wait_prompt():
        return [("prompt", False)]
    note = os.path.join(fix.work, "note.txt")
    with open(note, "w") as fh:
        fh.write("keep me")
    seg = sh.run_cmd(b"rm note.txt")
    sh.close()
    return [("rm denied by default policy", b"command denied by policy" in seg),
            ("file not removed", os.path.exists(note))]


def t_chat_offline(fix):
    sh = Shell(fix)
    if not sh.wait_prompt():
        return [("prompt", False)]
    base = len(sh.out)
    sh.send(b"? hi" + CR, t=0.3)
    sh.wait_prompt(base, timeout=10.0)
    seg = sh.segment(base)
    sh.close()
    return [("chat without provider is graceful", b"no LLM provider configured" in seg)]


# --------------------------------------------------------------------------- #
# CLI (non-interactive)
# --------------------------------------------------------------------------- #

def cli_env(fix):
    env = dict(os.environ)
    env["HOME"] = fix.home
    env["PATH"] = fix.path
    env["TERM"] = "dumb"
    return env


def t_cli_help(fix):
    out = subprocess.run([KRANTZ, "help"], capture_output=True, text=True, env=cli_env(fix))
    return [("help exits 0", out.returncode == 0),
            ("help shows usage", "Usage: krantz" in out.stdout)]


def t_cli_complete(fix):
    out = subprocess.run([KRANTZ, "complete", "src"], capture_output=True, text=True,
                         cwd=fix.work, env=cli_env(fix))
    return [("complete src -> src/", out.returncode == 0 and "src/" in out.stdout)]


def t_cli_config(fix):
    env = cli_env(fix)
    out = subprocess.run([KRANTZ, "config", "init"], capture_output=True, text=True, env=env)
    ok_init = out.returncode == 0
    out = subprocess.run([KRANTZ, "config", "show"], capture_output=True, text=True, env=env)
    ok_show = out.returncode == 0 and "history" in out.stdout
    out = subprocess.run([KRANTZ, "config", "deny", "add", "touch"],
                         capture_output=True, text=True, env=env)
    ok_add = out.returncode == 0
    out = subprocess.run([KRANTZ, "config", "deny", "list"],
                         capture_output=True, text=True, env=env)
    ok_list = out.returncode == 0 and "touch" in out.stdout
    return [("config init", ok_init), ("config show", ok_show),
            ("config deny add+list", ok_add and ok_list)]


def t_cli_llm(fix):
    out = subprocess.run([KRANTZ, "llm", "list"], capture_output=True, text=True, env=cli_env(fix))
    return [("llm list exits 0", out.returncode == 0)]


CASES = [
    ("completion-cycle", t_completion_cycle),
    ("completion-single", t_completion_single),
    ("completion-cd", t_completion_cd),
    ("completion-command", t_completion_command),
    ("completion-path", t_completion_path),
    ("completion-dotfile", t_completion_dotfile),
    ("completion-tilde", t_completion_tilde),
    ("completion-esc", t_completion_esc),
    ("completion-space-accept", t_completion_space_accept),
    ("completion-space-execute", t_completion_space_execute),
    ("path-navigation", t_path_navigation),
    ("pipes-redirection", t_pipes_redirection),
    ("variables", t_variables),
    ("trash", t_trash),
    ("policy", t_policy),
    ("chat-offline", t_chat_offline),
    ("cli-help", t_cli_help),
    ("cli-complete", t_cli_complete),
    ("cli-config", t_cli_config),
    ("cli-llm", t_cli_llm),
]


def main():
    filt = sys.argv[1] if len(sys.argv) > 1 else ""
    if not os.path.exists(KRANTZ):
        print(f"krantz binary not found: {KRANTZ} (set KRANTZ env or build first)")
        sys.exit(2)

    passed = failed = 0
    for name, fn in CASES:
        if filt and filt not in name:
            continue
        fix = Fixture()
        try:
            try:
                checks = fn(fix)
            except Exception as e:
                checks = [(f"{name} raised {type(e).__name__}: {e}", False)]
        finally:
            fix.cleanup()
        for label, ok in checks:
            if ok:
                passed += 1
                print(f"ok - {name}: {label}")
            else:
                failed += 1
                print(f"FAIL - {name}: {label}")

    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
