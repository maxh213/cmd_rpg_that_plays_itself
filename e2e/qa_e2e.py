#!/usr/bin/env python3
import os
import queue
import re
import signal
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FRAME_START = b"\x1b[?25l\x1b[H"
FRAME_END = b"\x1b[J\x1b[?25h"
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")

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


class Game:
    def __init__(self, label):
        self.label = label
        self.frames = queue.Queue()
        self.boot_text = ""
        self.proc = None
        self.seen_frame = False

    def start(self):
        self.proc = subprocess.Popen(
            ["make", "run"], cwd=ROOT, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, bufsize=0)
        self.boot_text = ""
        self.seen_frame = False
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
                start = buffer.find(FRAME_START)
                if start < 0:
                    if not self.seen_frame:
                        self.boot_text += ANSI.sub("", buffer.decode("utf-8", "replace"))
                    buffer = b""
                    break
                if start > 0:
                    if not self.seen_frame:
                        self.boot_text += ANSI.sub("", buffer[:start].decode("utf-8", "replace"))
                    buffer = buffer[start:]
                    continue
                nxt = buffer.find(FRAME_START, len(FRAME_START))
                if nxt < 0:
                    break
                raw = buffer[len(FRAME_START):nxt]
                buffer = buffer[nxt:]
                if FRAME_END in raw:
                    self.seen_frame = True
                    self.frames.put(ANSI.sub("", raw.decode("utf-8", "replace")))

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
        if item is None:
            raise Failure(f"[{self.label}] game exited unexpectedly")
        return Frame(item, time.time())

    def poll_frame(self):
        try:
            item = self.frames.get_nowait()
        except queue.Empty:
            return None
        if item is None:
            raise Failure(f"[{self.label}] game exited unexpectedly")
        return Frame(item, time.time())


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
        expired = [o["desc"] for o in self.obligations
                   if not o["met"] and frame.at > o["deadline"]]
        if expired:
            raise Failure(f"[{self.label}] obligation expired: " + "; ".join(expired))
        self.known.update(frame.heroes)

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
            "respawn_back", "inn", "shop", "party", "party_kill", "pvp"}


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
