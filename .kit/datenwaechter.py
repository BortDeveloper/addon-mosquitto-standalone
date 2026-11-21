#!/usr/bin/env python3
"""datenwaechter -- haelt identifizierbare Daten aus Git (stack-master ADR-0044, D.1/D.2).

Prueft Dateiinhalte, Dateinamen, Commit-Nachrichten und Autoren gegen
  1. die Klartextliste .local/verboten.txt (Klasse I, nur lokal + Backup; fehlt sie: fail closed),
  2. generische Muster: private und Tailnet-Adressen, MAC-Adressen, E-Mail-Adressen,
     Nutzerpfade (Windows/WSL/Home), private Schluessel, Chiffrat-Dateien (E2).
Ausnahmen stehen in projekt.toml, Abschnitt [datenwaechter] (erlaube_werte, ignoriere_pfade).
Kennungen, die einen Eintrag der Pruefliste enthalten muessen (Live-Topics, Entity-IDs, Logins),
gibt .local/erlaubt.txt frei: je Zeile ein Python-Regex gegen das ganze Token (Buchstaben, Ziffern,
_ . - / :), ohne Gross-/Kleinschreibung. Lokal, weil die Muster die Namen selbst tragen.

Modi:
  --staged             Index (pre-commit)
  --push               liest die pre-push-Zeilen von stdin, prueft die zu pushenden Commits
  --baum [REF]         ganzer Baum eines Commits (Standard HEAD)
  --bereich A..B       alle Commits eines Bereichs (Inhalte, Nachrichten, Autoren)
Optionen:
  --ci                 ohne .local/verboten.txt (CI, frischer Klon); nur generische Muster
  --repo PFAD          Repo-Wurzel (Standard: aktuelles Repo)

Exit: 0 sauber, 1 Funde, 2 Bedienungs- oder Konfigurationsfehler.
Ausgabe maskiert die Werte, damit Protokolle (CI, Terminal-Mitschnitt) sie nicht weitertragen.
"""
from __future__ import annotations

import fnmatch
import ipaddress
import os
import re
import subprocess
import sys

try:
    import tomllib  # Python >= 3.11
except ModuleNotFoundError:  # pragma: no cover
    tomllib = None

NULL_SHA = '0' * 40
MAX_BYTES = 2_000_000

RE_IPV4 = re.compile(r'(?<![\w.])(\d{1,3}(?:\.\d{1,3}){3})(?:/(\d{1,2}))?(?![\w.]*\d)')
RE_MAC = re.compile(r'(?<![0-9A-Fa-f:])((?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2})(?![0-9A-Fa-f:])')
RE_MAIL = re.compile(r'(?<![\w.+-])([\w.+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})')
RE_PFAD = re.compile(r'(?i)(?:[A-Z]:[\\/]+Users[\\/]+|/mnt/[a-z]/Users/|/home/|/Users/)([A-Za-z0-9._-]+)')
# Nur mit Schluesselmaterial: der blosse PEM-Kopf in Doku oder Code ist kein Fund
RE_SCHLUESSEL = re.compile(r'-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----\s*(?:[A-Za-z0-9+/=]\s*){100,}|AGE-SECRET-KEY-1[0-9A-Z]{20,}')

CHIFFRAT_ENDUNGEN = ('.enc', '.age', '.sbk', '.gpg', '.kdbx', '.p12', '.pfx')
MAIL_ERLAUBT = re.compile(
    r'(?i)^(?:noreply@.*|.*@users\.noreply\.github\.com|.*@(?:[\w-]+\.)*example\.(?:org|com|net)|.*@localhost'
    r'|.*@(?:[\w-]+\.)*(?:invalid|test|example|localhost)'  # RFC 2606/6761, reserviert
    r'|git@(?:github\.com|gitlab\.com|codeberg\.org))$')
# Platzhalter und Beispielnutzer in Pfaden
PFAD_ERLAUBT = {'user', 'username', 'runner', 'ubuntu', 'debian', 'pi', 'root', 'me', 'example',
                'operator', 'ihr-name', 'name', 'benutzer', 'vagrant', 'node', 'app', 'deploy', 'git',
                'www-data', 'admin', 'docker'}
TAILNET = ipaddress.ip_network('100.64.0.0/10')
# Ausdruecklich statt ip.is_private: das zaehlt auch Dokunetze (192.0.2.0/24 usw.) mit
PRIVAT = [ipaddress.ip_network(n) for n in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16')]
# Zeichen einer Kennung (Topic, Entity-ID, Login, Dateiname) fuer .local/erlaubt.txt
TOKEN_ZEICHEN = re.compile(r'[\w.\-/:]')


def maske(wert: str) -> str:
    if len(wert) <= 4:
        return '*' * len(wert)
    return wert[:3] + '...' + f'({len(wert)})'


def git(repo: str, *args: str, eingabe: bytes | None = None) -> bytes:
    return subprocess.run(['git', '-C', repo, *args], input=eingabe, capture_output=True,
                          check=True).stdout


class Waechter:
    def __init__(self, repo: str, ci: bool):
        self.repo = repo
        self.ci = ci
        self.funde: list[tuple[str, str, str, str]] = []
        self.verboten: list[str] = []
        self.erlaube: list[re.Pattern[str]] = []
        self.ignoriere: list[str] = []
        self.kennungen: list[re.Pattern[str]] = []
        self._lade_konfig()

    # -- Konfiguration ---------------------------------------------------------------------------
    def _lade_konfig(self) -> None:
        liste = os.path.join(self.repo, '.local', 'verboten.txt')
        beispiel = os.path.join(self.repo, 'local.beispiel')
        if os.path.isdir(beispiel) and os.path.realpath(os.path.join(self.repo, '.local')) == os.path.realpath(beispiel):
            print('datenwaechter: Hinweis: Beispielzustand (.local -> local.beispiel), nur die Beispiel-Pruefliste; '
                  'echte Daten aus dem Backup holen und kit/installieren.sh erneut ausfuehren', file=sys.stderr)
        if os.path.isfile(liste):
            with open(liste, encoding='utf-8') as f:
                self.verboten = [z.strip() for z in f if z.strip() and not z.lstrip().startswith('#')]
        elif not self.ci:
            raise SystemExit(self._fehler(
                f'{liste} fehlt (Klasse I, nur lokal + Backup). Anlegen oder aus dem Backup holen; '
                'nur in der CI mit --ci pruefen.'))
        # Freigegebene Kennungen (Live-Topics, Entity-IDs, Logins), die einen Eintrag der Pruefliste
        # enthalten: Python-Regex je Zeile gegen das ganze Token. Lokal, weil sie die Namen tragen.
        freigabe = os.path.join(self.repo, '.local', 'erlaubt.txt')
        if os.path.isfile(freigabe):
            with open(freigabe, encoding='utf-8') as f:
                zeilen = [z.strip() for z in f if z.strip() and not z.lstrip().startswith('#')]
            try:
                self.kennungen = [re.compile(z, re.IGNORECASE) for z in zeilen]
            except re.error as e:
                raise SystemExit(self._fehler(f'.local/erlaubt.txt: ungueltiges Muster: {e}'))
        pt = os.path.join(self.repo, 'projekt.toml')
        if os.path.isfile(pt):
            if tomllib is None:
                raise SystemExit(self._fehler('projekt.toml vorhanden, aber Python < 3.11 (kein tomllib)'))
            with open(pt, 'rb') as f:
                daten = tomllib.load(f).get('datenwaechter', {})
            try:
                self.erlaube = [re.compile(m) for m in daten.get('erlaube_werte', [])]
            except re.error as e:
                raise SystemExit(self._fehler(f'projekt.toml: ungueltiges Muster in erlaube_werte: {e}'))
            self.ignoriere = list(daten.get('ignoriere_pfade', []))

    @staticmethod
    def _fehler(text: str) -> int:
        print(f'datenwaechter: FEHLER: {text}', file=sys.stderr)
        return 2

    # -- Bewertung -------------------------------------------------------------------------------
    def _erlaubt(self, wert: str) -> bool:
        return any(m.fullmatch(wert) for m in self.erlaube)

    def _kennung_frei(self, text: str, anfang: int, ende: int) -> bool:
        """Treffer liegt in einem Token, das .local/erlaubt.txt ganz freigibt."""
        if not self.kennungen:
            return False
        while anfang > 0 and TOKEN_ZEICHEN.match(text[anfang - 1]):
            anfang -= 1
        while ende < len(text) and TOKEN_ZEICHEN.match(text[ende]):
            ende += 1
        token = text[anfang:ende]
        return any(m.fullmatch(token) for m in self.kennungen)

    def _ignoriert(self, pfad: str) -> bool:
        return any(fnmatch.fnmatch(pfad, g) for g in self.ignoriere)

    def _fund(self, ort: str, art: str, wert: str, zeile: str = '') -> None:
        self.funde.append((ort, art, maske(wert), zeile))

    def pruefe_text(self, ort: str, text: str, ist_pfadname: bool = False) -> None:
        klein = text.lower()
        for wort in self.verboten:
            start = 0
            w = wort.lower()
            while True:
                i = klein.find(w, start)
                if i < 0:
                    break
                if not self._kennung_frei(text, i, i + len(w)):
                    self._fund(self._zeilenort(ort, text, i, ist_pfadname), 'verboten', wort)
                start = i + len(w)
        for m in RE_IPV4.finditer(text):
            wert, praefix = m.group(1), m.group(2)
            try:
                ip = ipaddress.ip_address(wert)
            except ValueError:
                continue
            if praefix is not None and int(praefix) < 32:
                try:
                    ipaddress.ip_network(f'{wert}/{praefix}', strict=True)
                    continue  # Netzangabe (CIDR, Hostteil null) beschreibt einen Bereich, keinen Host
                except ValueError:
                    pass  # Host-Adresse mit Maske (Hostteil nicht null) bleibt ein Fund
            if not (ip in TAILNET or any(ip in n for n in PRIVAT)):
                continue
            if self._erlaubt(wert):
                continue
            art = 'tailnet-adresse' if ip in TAILNET else 'private-adresse'
            self._fund(self._zeilenort(ort, text, m.start(), ist_pfadname), art, wert)
        for m in RE_MAC.finditer(text):
            wert = m.group(1)
            if self._erlaubt(wert) or wert.lower() in ('00:00:00:00:00:00', 'ff:ff:ff:ff:ff:ff'):
                continue
            self._fund(self._zeilenort(ort, text, m.start(), ist_pfadname), 'mac-adresse', wert)
        for m in RE_MAIL.finditer(text):
            wert = m.group(1)
            if MAIL_ERLAUBT.search(wert) or self._erlaubt(wert):
                continue
            self._fund(self._zeilenort(ort, text, m.start(), ist_pfadname), 'mail', wert)
        for m in RE_PFAD.finditer(text):
            nutzer = m.group(1)
            if nutzer.lower() in PFAD_ERLAUBT or nutzer.startswith('<') or self._erlaubt(m.group(0)):
                continue
            self._fund(self._zeilenort(ort, text, m.start(), ist_pfadname), 'nutzerpfad', m.group(0))
        for m in RE_SCHLUESSEL.finditer(text):
            self._fund(self._zeilenort(ort, text, m.start(), ist_pfadname), 'privater-schluessel', m.group(0)[:40])

    @staticmethod
    def _zeilenort(ort: str, text: str, pos: int, ist_pfadname: bool) -> str:
        if ist_pfadname:
            return ort
        return f'{ort}:{text.count(chr(10), 0, pos) + 1}'

    def pruefe_datei(self, pfad: str, inhalt: bytes, ort: str | None = None) -> None:
        ort = ort or pfad
        if self._ignoriert(pfad):
            return
        self.pruefe_text(ort + ' (Dateiname)', pfad, ist_pfadname=True)
        if pfad.lower().endswith(CHIFFRAT_ENDUNGEN):
            self._fund(ort, 'chiffrat-datei (E2: nur Backup)', os.path.basename(pfad))
            return
        if b'\0' in inhalt[:8000] or len(inhalt) > MAX_BYTES:
            return
        self.pruefe_text(ort, inhalt.decode('utf-8', errors='replace'))

    def pruefe_commit(self, sha: str) -> None:
        kurz = sha[:8]
        roh = git(self.repo, 'show', '-s', '--format=%an%x00%ae%x00%cn%x00%ce%x00%B', sha).decode(
            'utf-8', errors='replace')
        an, ae, cn, ce, nachricht = roh.split('\0', 4)
        for name, mail, rolle in ((an, ae, 'autor'), (cn, ce, 'committer')):
            self.pruefe_text(f'commit {kurz} {rolle}', f'{name} <{mail}>', ist_pfadname=True)
        self.pruefe_text(f'commit {kurz} Nachricht', nachricht, ist_pfadname=True)

    # -- Modi ------------------------------------------------------------------------------------
    def modus_staged(self) -> None:
        namen = git(self.repo, 'diff', '--cached', '--name-only', '--diff-filter=ACMR', '-z').split(b'\0')
        for n in filter(None, namen):
            pfad = n.decode('utf-8', errors='replace')
            self.pruefe_datei(pfad, git(self.repo, 'show', f':{pfad}'))

    def modus_baum(self, ref: str) -> None:
        for eintrag in git(self.repo, 'ls-tree', '-r', '-z', ref).split(b'\0'):
            if not eintrag:
                continue
            kopf, pfad = eintrag.split(b'\t', 1)
            modus, typ, obj = kopf.split()
            if typ != b'blob' or modus == b'160000':
                continue
            self.pruefe_datei(pfad.decode('utf-8', errors='replace'), git(self.repo, 'cat-file', 'blob', obj.decode()))

    def modus_bereich(self, bereich: str) -> None:
        shas = git(self.repo, 'rev-list', '--reverse', bereich).decode().split()
        for sha in shas:
            self.pruefe_commit(sha)
            elternteil = git(self.repo, 'rev-list', '--parents', '-n', '1', sha).decode().split()[1:]
            basis = elternteil[0] if elternteil else '4b825dc642cb6eb9a060e54bf8d69288fbee4904'  # leerer Baum
            namen = git(self.repo, 'diff', '--name-only', '--diff-filter=ACMR', '-z', basis, sha).split(b'\0')
            for n in filter(None, namen):
                pfad = n.decode('utf-8', errors='replace')
                self.pruefe_datei(pfad, git(self.repo, 'show', f'{sha}:{pfad}'), f'{sha[:8]}:{pfad}')

    def modus_push(self, zeilen: list[str]) -> None:
        for z in zeilen:
            teile = z.split()
            if len(teile) != 4:
                continue
            _, lokal_sha, _, fern_sha = teile
            if lokal_sha == NULL_SHA:
                continue  # Loeschen einer Ref
            if fern_sha == NULL_SHA:
                # neue Ref: nur Commits, die auf keinem bekannten Remote-Zweig liegen
                self.modus_bereich_liste(git(self.repo, 'rev-list', lokal_sha, '--not', '--remotes').decode().split())
            else:
                self.modus_bereich(f'{fern_sha}..{lokal_sha}')

    def modus_bereich_liste(self, shas: list[str]) -> None:
        for sha in reversed(shas):
            self.modus_bereich(f'{sha}^!') if self._hat_eltern(sha) else self._wurzel(sha)

    def _hat_eltern(self, sha: str) -> bool:
        return len(git(self.repo, 'rev-list', '--parents', '-n', '1', sha).decode().split()) > 1

    def _wurzel(self, sha: str) -> None:
        self.pruefe_commit(sha)
        self.modus_baum(sha)

    # -- Bericht ---------------------------------------------------------------------------------
    def bericht(self) -> int:
        if not self.funde:
            print('datenwaechter: sauber')
            return 0
        gesehen = set()
        for ort, art, wert, _ in self.funde:
            schluessel = (ort, art, wert)
            if schluessel in gesehen:
                continue
            gesehen.add(schluessel)
            print(f'{ort}: {art}: {wert}')
        print(f'datenwaechter: {len(gesehen)} Fund(e). Klarwerte nach .local/werte.yml, im Repo '
              'Platzhalter wie <name>; echte Ausnahmen in projekt.toml [datenwaechter].', file=sys.stderr)
        return 1


def main(argv: list[str]) -> int:
    repo = None
    ci = False
    modus = None
    arg = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '--repo':
            repo = argv[i + 1]
            i += 1
        elif a == '--ci':
            ci = True
        elif a in ('--staged', '--push'):
            modus = a
        elif a in ('--baum', '--bereich'):
            modus = a
            if i + 1 < len(argv) and not argv[i + 1].startswith('--'):
                arg = argv[i + 1]
                i += 1
        elif a in ('-h', '--help'):
            print(__doc__)
            return 0
        else:
            print(f'datenwaechter: unbekannte Option {a}', file=sys.stderr)
            return 2
        i += 1
    if modus is None:
        print('datenwaechter: Modus fehlt (--staged, --push, --baum, --bereich)', file=sys.stderr)
        return 2
    try:
        repo = repo or git('.', 'rev-parse', '--show-toplevel').decode().strip()
    except subprocess.CalledProcessError:
        print('datenwaechter: kein Git-Repo', file=sys.stderr)
        return 2
    try:
        w = Waechter(repo, ci)
    except SystemExit as e:
        return int(e.code or 2)
    try:
        if modus == '--staged':
            w.modus_staged()
        elif modus == '--baum':
            w.modus_baum(arg or 'HEAD')
        elif modus == '--bereich':
            if not arg:
                print('datenwaechter: --bereich braucht A..B', file=sys.stderr)
                return 2
            w.modus_bereich(arg)
        else:
            w.modus_push(sys.stdin.read().splitlines())
    except subprocess.CalledProcessError as e:
        print(f'datenwaechter: git-Fehler: {e.stderr.decode(errors="replace").strip()}', file=sys.stderr)
        return 2
    return w.bericht()


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
