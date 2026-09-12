#!/usr/bin/env python3
import collections
import fcntl
import os
import pty
import queue
import re
import signal
import struct
import subprocess
import sys
import termios
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FRAME_START = b"\x1b[?25l"
FRAME_END = b"\x1b[75;1H\x1b[?25h"
CURSOR_SHOW = b"\x1b[?25h"
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
CSI = re.compile(r"\x1b\[([0-9;?]*)([A-Za-z])")
HOME = re.compile(rb"\x1b\[(?:1;1)?H")
BARE_HOME = re.compile(rb"\x1b\[H")
ERASE_BELOW = re.compile(rb"\x1b\[0?J")
CLEAR_SCREEN = re.compile(rb"\x1b\[[23]J")
CLEAR = "\x1b[H\x1b[2J"
PARK_RE = re.compile(rb"\x1b\[(\d+);1H\x1b\[\?25h$")
FRAME_ROWS = 74
FRAME_COLS = 85
PARK_ROW = 75
SCREEN_ROWS = PARK_ROW
RESIZE_SECONDS = 3
FIRST_UPDATE_LIMIT = 10000
UPDATE_LIMIT = 6000

PLAIN = frozenset()
BOLD = frozenset({"1"})
DIM = frozenset({"2"})
YELLOW = frozenset({"33"})
DIM_RED = frozenset({"2", "31"})
BOLD_CYAN = frozenset({"1", "36"})
BOLD_YELLOW = frozenset({"1", "33"})
MAP_STYLES = {
    ".": {frozenset({"2"})},
    "!": {frozenset({"1", "31"})},
    "$": {frozenset({"1", "33"})},
    "H": {frozenset({"1", "34"})},
    "+": {frozenset({"2", "36"})},
}
ROSTER_ICON_STYLES = {"&": frozenset({"36"}), "+": frozenset({"2"}), "@": frozenset({"32"})}
LEGEND_STYLES = [("@", "Hero", frozenset({"1", "32"})), ("&", "Party", frozenset({"1", "32"})),
                 ("!", "Enemy", frozenset({"1", "31"})), ("$", "Shop", frozenset({"1", "33"})),
                 ("H", "Inn", frozenset({"1", "34"}))]

NAME = r"[\w ]+"
HEADER_RE = re.compile(r"=== CMD RPG \[(\d+) moves\] ===")
BORDER_RE = re.compile(r"^  \+-{81}\+$")
ROW_RE = re.compile(r"^  \|(.{80})\|$")
HERO_RE = re.compile(
    r"^( +)([@&+]) ([\w ]+?) \((Hum|Dwf|DkE|Gnm|Trt|Duk)\) Lv(\d+)\s+"
    r"HP:(\d+)/(\d+)\s+XP:(\d+)/(\d+)\s+(\d+)g(?: \+(\d+)ATK)?(?: \+(\d+)DEF)?$")
PARTY_RE = re.compile(r"^  --- Party: (.+) ---$")
ENEMIES_RE = re.compile(r"^  Enemies on map: (\d+)$")
LOG_RE = re.compile(r"^    > (.+)$")
LEGEND = "@ Hero  & Party  ! Enemy  $ Shop  H Inn"

EVENT_RES = [
    ("kill", re.compile(r"^(%s) slew (%s)\(Lv(\d+)\) \[\+(\d+)XP \+(\d+)g\]$" % (NAME, NAME))),
    ("party_kill", re.compile(r"^(%s)'s party slew (%s)\(Lv(\d+)\) \[\+(\d+)XP \+(\d+)g\]$" % (NAME, NAME))),
    ("party_hit", re.compile(r"^(%s)'s party hit (%s) \(-\d+HP\)$" % (NAME, NAME))),
    ("hit_by", re.compile(r"^(%s) hit by (%s) \(-\d+HP\)$" % (NAME, NAME))),
    ("hit", re.compile(r"^(%s) hit (%s) \(-\d+HP\)$" % (NAME, NAME))),
    ("levelup", re.compile(r"^(%s) leveled up to Lv(\d+)!$" % NAME)),
    ("drop", re.compile(r"^(%s) found ([\w ]+)! \(\+(\d+)(HP| ATK| DEF| EVA)\)$" % NAME)),
    ("mauled", re.compile(r"^(%s) was mauled by (%s)!$" % (NAME, NAME))),
    ("slain_disband", re.compile(r"^(%s) was slain by (%s)! Party disbanded!$" % (NAME, NAME))),
    ("slain", re.compile(r"^(%s) was slain by (%s)!$" % (NAME, NAME))),
    ("respawned", re.compile(r"^(%s) respawned!$" % NAME)),
    ("appeared", re.compile(r"^A ([\w ]+) appeared!$")),
    ("rest", re.compile(r"^(%s) rests at the inn \(\+(\d+)HP\)$" % NAME)),
    ("bought", re.compile(r"^(%s) bought ([\w ]+) \(-(\d+)g\)$" % NAME)),
    ("party", re.compile(r"^(%s) and (%s) formed a party at (.+)!$" % (NAME, NAME))),
    ("clash", re.compile(r"^(%s) clashed with (%s) \(-\d+HP\)$" % (NAME, NAME))),
    ("defeated", re.compile(r"^(%s) defeated (%s)! \[\+(\d+)XP\]$" % (NAME, NAME))),
]

MAP_GLYPHS = set(".@!$H&+")
RACES = {"Hum", "Dwf", "DkE", "Gnm", "Trt", "Duk"}
EARLY_LOG_KINDS = {"clash", "hit", "hit_by"}

INSTANCES = int(os.environ.get("QA_E2E_INSTANCES", "8"))
GENERATIONS = int(os.environ.get("QA_E2E_GENERATIONS", "4"))
WANDER_SECONDS = float(os.environ.get("QA_E2E_WANDER", "10"))
GEN_BUDGET = float(os.environ.get("QA_E2E_GEN_BUDGET", "480"))
EVENT_BUDGET = float(os.environ.get("QA_E2E_EVENT_BUDGET", "2700"))
PARTY_KILL_WINDOW = float(os.environ.get("QA_E2E_PARTY_KILL_WINDOW", "600"))
SKIP_NESTED_GATE = os.environ.get("QA_E2E_SKIP_GATE") == "1"

STARTED = time.time()


class Failure(Exception):
    pass


class Hero:
    def __init__(self, match, party):
        self.indent = len(match.group(1))
        self.icon = match.group(2)
        self.name = match.group(3)
        self.race = match.group(4)
        self.level = int(match.group(5))
        self.hp = int(match.group(6))
        self.max_hp = int(match.group(7))
        self.xp = int(match.group(8))
        self.xp_needed = int(match.group(9))
        self.gold = int(match.group(10))
        self.atk = int(match.group(11) or 0)
        self.defense = int(match.group(12) or 0)
        self.width = len(match.group(0))
        self.party = party


class Frame:
    def __init__(self, text, at):
        self.at = at
        self.moves = None
        self.cells = {}
        self.roster = []
        self.heroes = {}
        self.parties = []
        self.enemies = None
        self.log = []
        self.legend_ok = False
        self.quiet = False
        self._parse(text)

    def _parse(self, text):
        lines = text.split("\n")
        i = self._header(lines)
        i = self._grid(lines, i)
        i = self._roster(lines, i)
        self._log(lines, i)

    def _header(self, lines):
        for i, line in enumerate(lines):
            match = HEADER_RE.search(line)
            if match:
                self.moves = int(match.group(1))
                return i + 1
        raise Failure("frame without header")

    def _grid(self, lines, i):
        while i < len(lines) and not BORDER_RE.match(lines[i]):
            i += 1
        if i == len(lines):
            raise Failure("frame without top border")
        i += 1
        for y in range(40):
            if i >= len(lines):
                raise Failure(f"grid row {y} missing")
            row = ROW_RE.match(lines[i])
            if not row:
                raise Failure(f"grid row {y} malformed: {lines[i]!r}")
            body = row.group(1)
            for x in range(40):
                glyph = body[2 * x]
                if glyph not in MAP_GLYPHS or body[2 * x + 1] != " ":
                    raise Failure(f"bad cell at ({x},{y})")
                if glyph != ".":
                    self.cells[(x, y)] = glyph
            i += 1
        if i >= len(lines) or not BORDER_RE.match(lines[i]):
            raise Failure("frame without bottom border")
        return i + 1

    def _roster(self, lines, i):
        while i < len(lines) and "Heroes:" not in lines[i]:
            if LEGEND in lines[i]:
                self.legend_ok = True
            i += 1
        if i == len(lines) or not self.legend_ok:
            raise Failure("frame without legend")
        i += 1
        current_party = None
        while i < len(lines) and not ENEMIES_RE.match(lines[i]):
            line = lines[i]
            party = PARTY_RE.match(line)
            hero = HERO_RE.match(line) if not party else None
            if party:
                current_party = party.group(1).split(" + ")
                self.parties.append(current_party)
            elif hero:
                if hero.group(2) == "@":
                    current_party = None
                parsed = Hero(hero, current_party)
                self.roster.append(parsed)
                self.heroes.setdefault(parsed.name, []).append(parsed)
            elif not line.strip():
                current_party = None
            i += 1
        if i == len(lines):
            raise Failure("frame without enemies summary")
        self.enemies = int(ENEMIES_RE.match(lines[i]).group(1))
        return i + 1

    def _log(self, lines, i):
        while i < len(lines) and "Log:" not in lines[i]:
            i += 1
        if i == len(lines):
            raise Failure("frame without log")
        i += 1
        while i < len(lines):
            entry = LOG_RE.match(lines[i])
            if entry:
                self.log.append(entry.group(1))
            i += 1
        self.quiet = self.log == ["(quiet...)"]

    def events(self):
        found = []
        for line in self.log:
            if line == "(quiet...)":
                continue
            for kind, pattern in EVENT_RES:
                match = pattern.match(line)
                if match:
                    found.append((kind, match.groups()))
                    break
            else:
                raise Failure(f"unrecognized log line: {line!r}")
        return found

    def glyphs(self, wanted):
        return {pos for pos, glyph in self.cells.items() if glyph in wanted}


def level_colour(level):
    if level >= 5:
        return "35"
    if level >= 3:
        return "33"
    return "32"


def hp_colour(hp, max_hp):
    if hp * 3 < max_hp:
        return frozenset({"31"})
    if hp * 3 < max_hp * 2:
        return frozenset({"33"})
    return frozenset({"32"})


class Screen:
    def __init__(self, cols=FRAME_COLS, rows=PARK_ROW):
        self.rows = collections.defaultdict(dict)
        self.cursor = (1, 1)
        self.style = PLAIN
        self.size = (cols, rows)

    def type(self, text):
        row, col = self.cursor
        for char in text:
            if char == "\n":
                row, col = row + 1, 1
            elif char == "\r":
                col = 1
            else:
                self.rows[row][col] = (char, PLAIN)
                col += 1
        self.cursor = (row, col)

    def apply(self, update):
        if update.startswith(CLEAR):
            self.rows.clear()
            update = update[len(CLEAR):]
        pos = 0
        for control in CSI.finditer(update):
            self._write(update[pos:control.start()])
            self._control(control.group(1), control.group(2))
            pos = control.end()
        self._write(update[pos:])
        self.cursor = (self.size[1], 1)
        self.style = PLAIN

    def _write(self, text):
        if not text:
            return
        row, col = self.cursor
        cols, rows = self.size
        if row >= rows or col + len(text) - 1 > cols:
            raise Failure(f"an update painted {text!r} outside the {cols}x{rows} "
                          f"terminal's frame, at row {row} column {col}")
        cells = self.rows[row]
        for char in text:
            if char < " " or char == "\x7f":
                raise Failure(f"an update carried the control character {char!r}")
            cells[col] = (char, self.style)
            col += 1
        self.cursor = (row, col)

    def _control(self, params, final):
        if final == "H":
            self.cursor = position(params)
        elif final == "K" and params in ("", "0"):
            self._erase_right()
        elif final == "m":
            self._select(params)
        else:
            raise Failure("an update used a control other than absolute addressing, "
                          f"erase-right and colour: ESC[{params}{final}")

    def _select(self, params):
        for code in params.split(";"):
            if code in ("", "0"):
                self.style = PLAIN
            else:
                self.style = self.style | {code}

    def _erase_right(self):
        row, col = self.cursor
        if row >= self.size[1]:
            raise Failure(f"an update erased row {row}, below the frame")
        cells = self.rows[row]
        for stale in [at for at in cells if at >= col]:
            del cells[stale]

    def picture(self):
        return Picture({row: dict(cells) for row, cells in self.rows.items() if cells})


class Picture:
    def __init__(self, rows):
        self.rows = rows
        self.lines = [self._line(row) for row in range(1, SCREEN_ROWS + 1)]

    def _line(self, row):
        cells = self.rows.get(row)
        if not cells:
            return ""
        return "".join(cells.get(col, (" ", PLAIN))[0] for col in range(1, max(cells) + 1))

    def line(self, row):
        return self.lines[row - 1]

    def style(self, row, col):
        return self.rows.get(row, {}).get(col, (" ", PLAIN))[1]

    def text(self):
        return "\n".join(self.lines)


class ScreenCheck:
    def __init__(self, picture):
        self.picture = picture
        self.heroes = []

    def run(self):
        row = self._header()
        row = self._grid(row)
        row = self._legend(row)
        row = self._roster(row)
        row = self._enemies(row)
        last = self._log(row)
        self._below(last)
        self._map_colours()
        return last

    def fail(self, row, what):
        raise Failure(f"screen row {row} {what}: {self.picture.line(row)!r}")

    def exact(self, row, text):
        if self.picture.line(row) != text:
            self.fail(row, f"should read {text!r}")

    def span(self, row, col, length, style, what):
        for at in range(col, col + length):
            found = self.picture.style(row, at)
            if found != style:
                raise Failure(f"screen row {row} column {at} ({what}) has colour "
                              f"{sorted(found)} instead of {sorted(style)}")

    def _header(self):
        line = self.picture.line(1)
        if not re.fullmatch(r"=== CMD RPG \[\d+ moves\] ===", line):
            self.fail(1, "should be the header on the top screen row")
        self.span(1, 1, len(line), BOLD_CYAN, "header")
        return 2

    def _border(self, row):
        if not BORDER_RE.match(self.picture.line(row)):
            self.fail(row, "should be a map border")
        self.span(row, 1, 2, PLAIN, "border indent")
        self.span(row, 3, 83, DIM, "border")

    def _grid(self, row):
        self._border(row)
        for y in range(40):
            line = self.picture.line(row + 1 + y)
            if not ROW_RE.match(line):
                self.fail(row + 1 + y, f"should be map row {y}")
            self.span(row + 1 + y, 3, 1, DIM, "left side bar")
            self.span(row + 1 + y, 84, 1, DIM, "right side bar")
        self._border(row + 41)
        return row + 42

    def _legend(self, row):
        self.exact(row, "  " + LEGEND)
        for glyph, word, style in LEGEND_STYLES:
            offset = LEGEND.index(f"{glyph} {word}")
            self.span(row, 3 + offset, 1, style, f"legend {glyph}")
            self.span(row, 5 + offset, len(word), PLAIN, f"legend {word}")
        self.exact(row + 1, "  Heroes:")
        self.span(row + 1, 3, 7, BOLD_CYAN, "Heroes:")
        return row + 2

    def _roster(self, row):
        while not ENEMIES_RE.match(self.picture.line(row)):
            if row >= FRAME_ROWS:
                self.fail(row, "roster runs off the frame")
            party = PARTY_RE.match(self.picture.line(row))
            if party:
                row = self._party(row, len(party.group(1).split(" + ")))
            else:
                row = self._hero(row, 4, "@")
        return row

    def _party(self, row, members):
        self.span(row, 3, len(self.picture.line(row)) - 2, BOLD_CYAN, "party header")
        row = self._hero(row + 1, 4, "&")
        for _ in range(members - 1):
            row = self._hero(row, 6, "+")
        return row

    def _hero(self, row, indent, icon):
        line = self.picture.line(row)
        match = HERO_RE.match(line)
        if not match or len(match.group(1)) != indent or match.group(2) != icon:
            self.fail(row, f"should be a hero line indented {indent} with icon {icon}")
        hp_start = match.start(6) - 3
        self.span(row, 1, indent, PLAIN, "roster indent")
        self.span(row, indent + 1, 1, ROSTER_ICON_STYLES[icon], "roster icon")
        self.span(row, match.start(3) + 1, len(match.group(3)), BOLD, "hero name")
        self.span(row, match.end(3) + 1, hp_start - match.end(3), PLAIN, "race and level")
        self.span(row, hp_start + 1, match.end(7) - hp_start,
                  hp_colour(int(match.group(6)), int(match.group(7))), "HP")
        self.span(row, match.end(7) + 1, match.start(10) - match.end(7), PLAIN, "XP")
        self.span(row, match.start(10) + 1, match.end(10) - match.start(10) + 1, YELLOW, "gold")
        self.span(row, match.end(10) + 2, len(line) - match.end(10) - 1, PLAIN, "bonus")
        self.heroes.append((icon, int(match.group(5))))
        return row + 1

    def _enemies(self, row):
        self.span(row, 3, len(self.picture.line(row)) - 2, DIM_RED, "enemy count")
        self.exact(row + 1, "  Log:")
        self.span(row + 1, 3, 4, BOLD_YELLOW, "Log:")
        return row + 2

    def _log(self, row):
        first = row
        while row <= FRAME_ROWS and LOG_RE.match(self.picture.line(row)):
            line = self.picture.line(row)
            if line == "    > (quiet...)":
                self.span(row, 5, len(line) - 4, DIM, "quiet line")
            else:
                self.span(row, 5, 2, DIM, "log marker")
                self.span(row, 7, len(line) - 6, PLAIN, "log entry")
            row += 1
        count = row - first
        if count == 0:
            self.fail(first, "should be the first log line")
        if count > 12:
            self.fail(row - 1, "is a thirteenth log line")
        if count > 1 and "    > (quiet...)" in self.picture.lines[first - 1:row - 1]:
            self.fail(first, "shows a stale quiet line among the log entries")
        return row - 1

    def _below(self, last):
        for row in range(last + 1, SCREEN_ROWS + 1):
            if self.picture.line(row):
                self.fail(row, "should be blank below the frame, but holds stale text")

    def _map_colours(self):
        allowed = {icon: {frozenset({"1", level_colour(level)}) for i, level in self.heroes if i == icon}
                   for icon in "@&"}
        for y in range(40):
            row = 3 + y
            for x in range(40):
                col = 4 + 2 * x
                glyph = self.picture.line(row)[col - 1]
                styles = MAP_STYLES.get(glyph) or allowed.get(glyph, set())
                if self.picture.style(row, col) not in styles:
                    raise Failure(f"map cell ({x},{y}) {glyph!r} has colour "
                                  f"{sorted(self.picture.style(row, col))}, not one of "
                                  f"{[sorted(s) for s in styles]}")


def position(params):
    if not params:
        return (1, 1)
    row, _, col = params.partition(";")
    return (int(row), int(col or "1"))


class Game:
    def __init__(self, label):
        self.label = label
        self.frames = queue.Queue()
        self.proc = None
        self.exit_reason = "game exited unexpectedly"
        self._reset_stream()

    def _reset_stream(self):
        self.boot_text = ""
        self.seen_frame = False
        self.screen = Screen()
        self.first_size = None
        self.largest_update = 0
        self.tallest = 0
        self.last_moves = None

    def start(self):
        self.proc = subprocess.Popen(
            ["make", "run"], cwd=ROOT, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, bufsize=0)
        self._reset_stream()
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self):
        buffer = b""
        fd = self.proc.stdout.fileno()
        while True:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                chunk = b""
            if not chunk:
                self.frames.put(None)
                return
            buffer += chunk
            while True:
                end = buffer.find(FRAME_END)
                shown = buffer.find(CURSOR_SHOW)
                if shown >= 0 and shown != end + len(FRAME_END) - len(CURSOR_SHOW):
                    self.exit_reason = "an update did not end by parking the cursor on row 75"
                    self.frames.put(None)
                    return
                if end < 0:
                    break
                update = buffer[:end + len(FRAME_END)]
                buffer = buffer[end + len(FRAME_END):]
                try:
                    self._apply(update)
                except Failure as problem:
                    self.exit_reason = str(problem)
                    self.frames.put(None)
                    return

    def _apply(self, update):
        start = update.find(FRAME_START)
        if start < 0:
            raise Failure("an update arrived without its cursor-hide marker")
        if self.seen_frame and start > 0:
            raise Failure(f"bytes outside the update brackets: {update[:start][:80]!r}")
        if not self.seen_frame:
            boot = ANSI.sub("", update[:start].decode("utf-8", "replace"))
            self.boot_text += boot
            self.screen.type(boot)
        piece = update[start:]
        body = piece[len(FRAME_START):-len(FRAME_END)]
        self._check_bytes(len(piece), body)
        self.screen.apply(body.decode("utf-8", "replace"))
        self.seen_frame = True
        self.frames.put(self.screen.picture())

    def _check_bytes(self, size, body):
        if FRAME_START in body or CURSOR_SHOW in body:
            raise Failure("an update hid or showed the cursor between its brackets")
        if not self.seen_frame:
            self._check_first(size, body)
            return
        if size >= UPDATE_LIMIT:
            raise Failure(f"a later update is {size} bytes, not under {UPDATE_LIMIT}")
        if CLEAR_SCREEN.search(body):
            raise Failure("a later update cleared the screen with no size change")
        if HOME.search(body):
            raise Failure("a later update addressed home again: a full repaint")
        if ERASE_BELOW.search(body):
            raise Failure("a later update erased below the cursor: a full repaint")
        self.largest_update = max(self.largest_update, size)

    def _check_first(self, size, body):
        if not body.startswith(CLEAR.encode()):
            raise Failure("the first update does not start by clearing the screen")
        if size >= FIRST_UPDATE_LIMIT:
            raise Failure(f"the first update is {size} bytes, not under {FIRST_UPDATE_LIMIT}")
        if (len(BARE_HOME.findall(body)) != 1 or len(CLEAR_SCREEN.findall(body)) != 1
                or ERASE_BELOW.search(body)):
            raise Failure("the first update holds more than one home or clear, or an erase-below")
        self.first_size = size

    def stop(self):
        if not self.proc or self.proc.poll() is not None:
            return
        self.proc.send_signal(signal.SIGINT)
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=5)

    def next_frame(self, timeout):
        try:
            item = self.frames.get(timeout=timeout)
        except queue.Empty:
            raise Failure(f"[{self.label}] no frame within {timeout:.0f}s")
        return self._frame(item)

    def poll_frame(self):
        try:
            item = self.frames.get_nowait()
        except queue.Empty:
            return None
        return self._frame(item)

    def _frame(self, item):
        if item is None:
            raise Failure(f"[{self.label}] {self.exit_reason}")
        try:
            last_row = ScreenCheck(item).run()
            frame = Frame(item.text(), time.time())
        except Failure as problem:
            raise Failure(f"[{self.label}] {problem}\n{item.text()}")
        if self.last_moves is not None and frame.moves < self.last_moves:
            raise Failure(f"[{self.label}] move counter went backwards")
        self.last_moves = frame.moves
        self.tallest = max(self.tallest, last_row)
        return frame


class Engine:
    def __init__(self, label, shared):
        self.label = label
        self.flags = shared
        self.obligations = []
        self.reset_for_boot()

    def reset_for_boot(self):
        self.obligations = [o for o in self.obligations if o["met"]]
        self.rests = {}
        self.known = {}
        self.floor_enemies = None
        self.floor_enemies_at = None
        self.floor_heroes = None
        self.floor_heroes_at = None
        self.flags_respawned = set()
        self.last_log = 0
        self.last_enemies = None

    def need(self, desc, deadline, check, key=None):
        if key:
            for obligation in self.obligations:
                if not obligation["met"] and obligation.get("key") == key:
                    obligation.update(desc=desc, deadline=deadline, check=check)
                    return
        self.obligations.append(
            {"desc": desc, "deadline": deadline, "check": check, "met": False, "key": key})

    def feed(self, frame):
        if "+" in frame.cells.values():
            raise Failure(f"[{self.label}] a + glyph appeared on the map")
        self._population(frame, frame.enemies, 12, "enemies")
        self._population(frame, len(frame.roster), 6, "heroes")
        events = frame.events()
        for kind, groups in events:
            handler = getattr(self, f"on_{kind}", None)
            if handler:
                handler(groups, frame, events)
        for obligation in self.obligations:
            if not obligation["met"] and obligation["check"](frame):
                obligation["met"] = True
        self._shrinks(frame)
        expired = [o["desc"] for o in self.obligations
                   if not o["met"] and frame.at > o["deadline"]]
        if expired:
            raise Failure(f"[{self.label}] obligation expired: " + "; ".join(expired))
        self.known.update(frame.heroes)

    def _shrinks(self, frame):
        if self.last_log >= 2 and frame.quiet:
            self.flags.add("log_shrink")
        self.last_log = len(frame.log)
        if self.last_enemies is not None and self.last_enemies >= 10 > frame.enemies:
            self.flags.add("enemy_count_narrowed")
        self.last_enemies = frame.enemies
        for name, afters in frame.heroes.items():
            befores = self.known.get(name, [])
            if any(a.width < b.width for a in afters for b in befores):
                self.flags.add("line_narrowed")
            if any(a.gold < 10 <= b.gold for a in afters for b in befores):
                self.flags.add("gold_narrowed")

    def _population(self, frame, count, full, label):
        floor_attr, at_attr = f"floor_{label}", f"floor_{label}_at"
        if count > full:
            raise Failure(f"[{self.label}] {label} count above {full}: {count}")
        if count == full:
            setattr(self, floor_attr, None)
            return
        lowest = getattr(self, floor_attr)
        if lowest is None or count != lowest:
            setattr(self, floor_attr, count)
            setattr(self, at_attr, frame.at)
        elif frame.at - getattr(self, at_attr) > 10:
            raise Failure(f"[{self.label}] {label} population stuck at {count}/{full} for over 10s")

    def on_hit(self, groups, frame, events):
        self.flags.add("hit")

    def on_hit_by(self, groups, frame, events):
        self.flags.add("hit")

    def on_kill(self, groups, frame, events):
        name, _enemy, _level, _xp, gold = groups
        gain = int(gold)
        befores = self.known.get(name, [])
        afters = frame.heroes.get(name, [])
        rewarded = any(
            after.gold >= before.gold + gain - 8
            or after.xp > before.xp or after.level > before.level
            or after.atk > before.atk or after.defense > before.defense
            for before in befores for after in afters)
        if befores and afters and not rewarded:
            raise Failure(f"[{self.label}] {name}'s roster shows no reward for the kill")
        self.flags.add("kill")
        self.need("an enemy appeared within 8s of a kill", frame.at + 8,
                  lambda f: "respawn_enemy" in self.flags, key="appeared")

    def on_appeared(self, groups, frame, events):
        self.flags.add("respawn_enemy")

    def on_levelup(self, groups, frame, events):
        name, level = groups
        if level != "2" or "levelup" in self.flags:
            return
        self.flags.add("levelup")

        def shown(f):
            return any(h.level == 2 and h.xp_needed == 5 for h in f.heroes.get(name, []))

        def refilled(f):
            return any(h.level >= 2 and h.hp == h.max_hp for h in f.heroes.get(name, []))

        self.need(f"{name} roster shows Lv2 with XP counting toward 5", frame.at + 30, shown)
        self.need(f"{name} HP refilled on level-up", frame.at + 120, refilled)

    def on_drop(self, groups, frame, events):
        name, _item, amount, kind = groups
        self.flags.add("drop")
        befores = self.known.get(name, [])
        if not befores or "drop_stat" in self.flags:
            return
        bonus = int(amount)
        if kind.strip() == "ATK":
            floor = min(b.atk for b in befores) + bonus
            check = lambda f: any(h.atk >= floor for h in f.heroes.get(name, []))
        elif kind.strip() == "DEF":
            floor = min(b.defense for b in befores) + bonus
            check = lambda f: any(h.defense >= floor for h in f.heroes.get(name, []))
        else:
            return
        self.flags.add("drop_stat")
        self.need(f"{name} roster gains a stat suffix for the drop", frame.at + 5, check)

    def on_mauled(self, groups, frame, events):
        self._death(groups[0], frame)

    def on_slain(self, groups, frame, events):
        self._death(groups[0], frame)

    def on_slain_disband(self, groups, frame, events):
        self._death(groups[0], frame)

    def _death(self, name, frame):
        self.flags.add("death")
        if len(frame.roster) > 5:
            raise Failure(f"[{self.label}] roster did not drop to 5 after {name} died")
        self.need(f"{name} respawned within 8s of death", frame.at + 8,
                  lambda f, n=name: n in self.flags_respawned)

    def on_respawned(self, groups, frame, events):
        self.flags_respawned.add(groups[0])
        if "death" in self.flags:
            self.flags.add("respawn_back")
            self.need("roster back to 6 after the respawn", frame.at + 8,
                      lambda f: len(f.roster) == 6, key="back_to_6")

    def on_rest(self, groups, frame, events):
        name, _healed = groups
        hps = [h.hp for h in frame.heroes.get(name, [])]
        if not hps:
            return
        hp = max(hps)
        if name in self.rests and hp > self.rests[name]:
            self.flags.add("inn")
        self.rests[name] = hp

    def on_bought(self, groups, frame, events):
        name, _item, _cost = groups
        if "shop" in self.flags:
            return
        befores = self.known.get(name, [])
        afters = frame.heroes.get(name, [])
        if not befores or not afters:
            return
        spent = sum(int(g[2]) for k, g in events if k == "bought" and g[0] == name)
        kills = sum(1 for k, g in events if k in ("kill", "party_kill") and g[0] == name)
        paid = any(before.gold - spent <= after.gold <= before.gold - spent + 15 * kills
                   for before in befores for after in afters)
        if not paid:
            raise Failure(f"[{self.label}] {name}'s gold did not drop by the price shown")
        self.flags.add("shop")

    def on_party(self, groups, frame, events):
        a, b, _inn = groups
        self.need("a party kill line", frame.at + PARTY_KILL_WINDOW,
                  lambda f: "party_kill" in self.flags, key="party_kill")
        if "party" in self.flags:
            return
        self.flags.add("party")
        pair = {a, b}

        def shown(f):
            if "&" not in f.cells.values():
                return False
            for members in f.parties:
                if set(members) != pair:
                    continue
                icons = {h.icon: h.indent for h in f.roster if h.party is members}
                if icons.get("&") == 4 and icons.get("+") == 6:
                    return True
            return False

        self.need(f"party {a} + {b} renders as & on the map with a + follower in the roster",
                  frame.at + 10, shown)

    def on_party_kill(self, groups, frame, events):
        self.flags.add("party_kill")

    def on_clash(self, groups, frame, events):
        self.flags.add("pvp")

    def on_defeated(self, groups, frame, events):
        _winner, loser, _xp = groups
        self.flags.add("pvp")
        if "pvp_respawn" not in self.flags:
            self.flags.add("pvp_respawn")
            self.need(f"{loser} respawned within 8s of defeat", frame.at + 8,
                      lambda f, n=loser: n in self.flags_respawned)

    def unmet(self):
        return [o["desc"] for o in self.obligations if not o["met"]]


REQUIRED = {"hit", "kill", "respawn_enemy", "levelup", "drop", "death",
            "respawn_back", "inn", "shop", "party", "party_kill", "pvp",
            "log_shrink", "line_narrowed"}


def check_boot(game, engine):
    frame = game.next_frame(timeout=25)
    for expected in ["Starting CMD RPG...", "World is alive. Watch the heroes fight!",
                     "Press Ctrl+C to stop."]:
        if expected not in game.boot_text:
            raise Failure(f"[{game.label}] missing boot string: {expected!r}")
    if len(frame.roster) != 6:
        raise Failure(f"[{game.label}] first frame roster is not exactly 6 heroes")
    for hero in frame.roster:
        if hero.level != 1:
            raise Failure(f"[{game.label}] {hero.name} is not Lv1 on the first frame")
        if hero.race not in RACES:
            raise Failure(f"[{game.label}] {hero.name} has unknown race tag {hero.race}")
    if frame.enemies != 12:
        raise Failure(f"[{game.label}] first frame does not show 12 enemies")
    if not frame.quiet:
        kinds = {kind for kind, _ in frame.events()}
        if not kinds <= EARLY_LOG_KINDS:
            raise Failure(f"[{game.label}] first frame log not quiet: {frame.log}")
    engine.feed(frame)
    return frame


def drain(pairs):
    for game, engine in pairs:
        while True:
            frame = game.poll_frame()
            if frame is None:
                break
            engine.feed(frame)


def global_missing(engines, shared):
    gaps = {f"missing event: {flag}" for flag in sorted(REQUIRED - shared)}
    for _game, engine in engines:
        gaps.update(f"unmet: {desc}" for desc in engine.unmet())
    return sorted(gaps)


def report_rendering(gen_no, pairs):
    games = [game for game, _engine in pairs if game.first_size]
    if not games:
        return
    print(f"[gen {gen_no}] smooth rendering ok on {len(games)} worlds at the 85x75 fallback: "
          f"one clear-screen, on the first update, and no erase-below; first update at most {max(g.first_size for g in games)} "
          f"bytes, later updates at most {max(g.largest_update for g in games)} bytes, all "
          f"parked at row 75; only absolute addressing, erase-right and colour; screen never "
          f"stale, always well-formed and correctly coloured; tallest frame "
          f"{max(g.tallest for g in games)} rows", flush=True)


class PtyGame:
    def __init__(self, cols, rows):
        self.master, slave = pty.openpty()
        self.data = b""
        self.seen = 0
        self.lock = threading.Lock()
        self._size(cols, rows)
        self.proc = subprocess.Popen(["make", "-s", "run"], cwd=ROOT, stdin=slave, stdout=slave,
                                     stderr=slave, start_new_session=True)
        os.close(slave)
        threading.Thread(target=self._pump, daemon=True).start()

    def _size(self, cols, rows):
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def _pump(self):
        while True:
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                return
            if not chunk:
                return
            with self.lock:
                self.data += chunk

    def resize(self, cols, rows):
        self._size(cols, rows)
        os.killpg(self.proc.pid, signal.SIGWINCH)

    def next_update(self, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                pieces = self.data.split(FRAME_START)[1:]
            complete = [piece for piece in pieces if piece.endswith(CURSOR_SHOW)]
            if len(complete) > self.seen:
                self.seen += 1
                return complete[self.seen - 1]
            time.sleep(0.02)
        raise Failure(f"[pty] no update within {timeout}s")

    def await_repaint(self, screen, cols, rows, timeout):
        deadline = time.time() + timeout
        while True:
            update = self.next_update(max(0.1, deadline - time.time()))
            park = PARK_RE.search(update)
            if not park:
                raise Failure(f"[pty] an update did not end with a park: {update[-40:]!r}")
            body = update[:park.start()].decode("utf-8", "replace")
            if body.startswith(CLEAR):
                screen.size = (cols, rows)
            if int(park.group(1)) != screen.size[1]:
                raise Failure(f"[pty] an update parked on row {park.group(1)}, not {screen.size[1]}")
            if len(CLEAR_SCREEN.findall(update)) != int(body.startswith(CLEAR)):
                raise Failure("[pty] an update cleared the screen other than at its start")
            screen.apply(body)
            if body.startswith(CLEAR):
                return screen.picture()
            if time.time() > deadline:
                raise Failure(f"[pty] no full repaint at {cols}x{rows} within {timeout}s")

    def stop(self):
        try:
            os.killpg(self.proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.proc.wait(timeout=5)
        os.close(self.master)


def expect_line(picture, row, check, what):
    if not check(picture.line(row)):
        raise Failure(f"[pty] screen row {row} should be {what}: {picture.line(row)!r}\n"
                      + picture.text())


def check_80x24(picture):
    expect_line(picture, 1, lambda l: HEADER_RE.fullmatch(l), "the header")
    for row in (2, 9):
        expect_line(picture, row, lambda l: l == "  +-------------+", "a 17-column border")
    for row in range(3, 9):
        expect_line(picture, row, lambda l: re.fullmatch(r"  \|(?:[.@!$H&+] ){6}\|", l),
                    "a 6-cell grid row")
    expect_line(picture, 10, lambda l: l == "  " + LEGEND, "the legend")
    expect_line(picture, 11, lambda l: l == "  Heroes:", "Heroes:")
    names = {m.group(3) for m in (HERO_RE.match(picture.line(r)) for r in range(12, 21)) if m}
    if len(names) != 6:
        raise Failure(f"[pty] the 80x24 roster lists {sorted(names)}, not 6 heroes\n" + picture.text())
    log_row = picture.lines.index("  Log:") + 1
    expect_line(picture, log_row - 1, lambda l: ENEMIES_RE.match(l), "the enemy count")
    expect_line(picture, log_row + 1, lambda l: LOG_RE.match(l), "a log line")
    expect_line(picture, 24, lambda l: l == "", "the empty park row")


def check_notice(picture):
    expect_line(picture, 1, lambda l: l == "Terminal too small", "the notice")
    if any(picture.lines[1:]):
        raise Failure("[pty] the too-small screen shows more than the notice\n" + picture.text())


def check_20x10(picture):
    for row in (2, 4):
        expect_line(picture, row, lambda l: l == "  +---+", "a 1-cell border")
    expect_line(picture, 3, lambda l: re.fullmatch(r"  \|[.@!$H&+] \|", l), "the 1-cell grid row")
    expect_line(picture, 5, lambda l: l == "  @ Hero  & Party  !", "the legend cut at column 20")
    expect_line(picture, 6, lambda l: l == "  Heroes:", "Heroes:")
    for row in range(7, 10):
        expect_line(picture, row, lambda l: len(l) == 20, "a hero line cut at column 20")
    expect_line(picture, 10, lambda l: l == "", "the empty park row")


def check_terminal_sizes():
    subprocess.run(["make", "-s"], cwd=ROOT, check=True)
    game = PtyGame(80, 24)
    try:
        screen = Screen(80, 24)
        check_80x24(game.await_repaint(screen, 80, 24, 25))
        game.resize(85, 75)
        ScreenCheck(game.await_repaint(screen, 85, 75, RESIZE_SECONDS)).run()
        game.resize(19, 24)
        check_notice(game.await_repaint(screen, 19, 24, RESIZE_SECONDS))
        for _ in range(2):
            quiet = game.next_update(RESIZE_SECONDS)
            if quiet != b"\x1b[24;1H\x1b[?25h":
                raise Failure(f"[pty] a too-small tick wrote more than the park: {quiet!r}")
        game.resize(20, 10)
        check_20x10(game.await_repaint(screen, 20, 10, RESIZE_SECONDS))
        game.resize(80, 24)
        check_80x24(game.await_repaint(screen, 80, 24, RESIZE_SECONDS))
    finally:
        game.stop()
    print("terminal sizes ok in a pty: 80x24 shows every section, resizes to 85x75, 19x24, "
          "20x10 and back repaint in full within one tick, the too-small notice ticks only "
          "park, and nothing is drawn outside the terminal", flush=True)


def run_gate_step():
    if SKIP_NESTED_GATE:
        print("step 13 skipped (QA_E2E_SKIP_GATE=1)", flush=True)
        return
    result = subprocess.run(
        ["marestail", "gate"], cwd=ROOT, capture_output=True, text=True, timeout=1800)
    lines = (result.stdout + result.stderr).strip().splitlines()
    if not lines or lines[-1].strip() != "GATE PASSED":
        raise Failure("nested marestail gate failed:\n" + "\n".join(lines[-15:]))


def generation(gen_no, shared):
    subprocess.run(["make", "-s"], cwd=ROOT, check=True)
    games = [Game(f"world{i}") for i in range(INSTANCES)]
    pairs = [(game, Engine(game.label, shared)) for game in games]
    for game, _engine in pairs:
        game.start()
    try:
        for game, engine in pairs:
            check_boot(game, engine)
        print(f"[gen {gen_no}] steps 1-2 ok on {INSTANCES} worlds: boot strings, header, "
              f"40x40 grid, legend, 6 Lv1 heroes, 12 enemies, quiet log", flush=True)
        return pairs
    except BaseException:
        for game, _engine in pairs:
            game.stop()
        raise


def watch_events(gen_no, pairs, shared, deadline):
    primary_game, primary_engine = pairs[0]
    first = primary_game.next_frame(timeout=25)
    start_at, start_enemy = first.glyphs("@"), first.glyphs("!")
    start_moves = first.moves
    frames = 0
    last = first
    primary_engine.feed(first)
    wander_deadline = time.time() + WANDER_SECONDS
    while time.time() < wander_deadline:
        frame = primary_game.next_frame(timeout=5)
        if frame.moves < last.moves:
            raise Failure(f"[{primary_game.label}] move counter went backwards")
        primary_engine.feed(frame)
        drain(pairs[1:])
        frames += 1
        last = frame
    if last.moves <= start_moves:
        raise Failure(f"[{primary_game.label}] move counter did not climb")
    if last.glyphs("@") == start_at:
        raise Failure(f"[{primary_game.label}] @ glyphs did not move")
    if last.glyphs("!") == start_enemy:
        raise Failure(f"[{primary_game.label}] ! glyphs did not move")
    if not WANDER_SECONDS * 1.2 <= frames <= WANDER_SECONDS * 3.5:
        raise Failure(f"[{primary_game.label}] redraw rate off: {frames} frames")
    print(f"[gen {gen_no}] step 3 ok: counter climbs, @ and ! move, grid holds", flush=True)
    reported = set(shared)
    while True:
        drain(pairs)
        for flag in sorted(shared - reported):
            print(f"    [{time.time() - STARTED:7.1f}s] observed: {flag}", flush=True)
        reported = set(shared)
        if REQUIRED <= shared and not any(engine.unmet() for _g, engine in pairs):
            return True
        if time.time() > deadline:
            return False
        time.sleep(0.05)


def main():
    check_terminal_sizes()
    shared = set()
    deadline = time.time() + EVENT_BUDGET
    for gen_no in range(1, GENERATIONS + 1):
        pairs = generation(gen_no, shared)
        try:
            gen_deadline = min(deadline, time.time() + GEN_BUDGET)
            finished = watch_events(gen_no, pairs, shared, gen_deadline)
        finally:
            for game, _engine in pairs:
                game.stop()
        report_rendering(gen_no, pairs)
        if finished:
            break
        print(f"[gen {gen_no}] missing: {global_missing(pairs, shared)}", flush=True)
        if gen_no == GENERATIONS or time.time() >= deadline:
            raise Failure("event checklist incomplete: "
                          + "; ".join(global_missing(pairs, shared)))
        print(f"starting generation {gen_no + 1} with fresh worlds", flush=True)
    print("steps 4-12 ok: combat, kill reward, enemy respawn, level-up, loot, hero death "
          "and respawn, inn, shop, party, PvP", flush=True)
    run_gate_step()
    print("step 13 ok: marestail gate prints GATE PASSED", flush=True)
    print("QA E2E PASSED", flush=True)


try:
    main()
except Failure as problem:
    print(f"QA E2E FAILED: {problem}", flush=True)
    sys.exit(1)
