using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace NuclearTrollstav
{
    /// <summary>Tests of the plugin's own log file (src/LogFile.cs): which lines go in, how they look, and the file itself.</summary>
    public static partial class TestMain
    {
        private static readonly int[] Levels =
        {
            0, LogRules.Fatal, LogRules.Error, LogRules.Warning, LogRules.Message, LogRules.Info, LogRules.Debug,
            LogRules.Error | LogRules.Warning, LogRules.Message | LogRules.Info, 63,
        };

        private static readonly string[] Texts =
        {
            null, "", "Sending an alert failed", "NuclearTrollstav", "  at NuclearTrollstav.Diag.Equip ()",
            "at nucleartrollstav.Alerts.Tick", "NuclearTrollsta", "[Error  : Unity Log] NullReferenceException",
        };

        private static void LogFilterTests()
        {
            // Every combination, against the rule written out: a line goes in when a setting is on, it is the plugin's
            // own or names the plugin, and it is a problem or VerboseLog is on.
            int combos = 0;
            bool all = true;
            foreach (bool errorLog in new[] { false, true })
            foreach (bool verbose in new[] { false, true })
            foreach (bool own in new[] { false, true })
            foreach (int level in Levels)
            foreach (string text in Texts)
            {
                bool names = text != null && text.ToLowerInvariant().Contains("nucleartrollstav");
                bool problem = (level & 7) != 0;
                bool want = (errorLog || verbose) && (own || names) && (verbose || problem);
                bool got = LogRules.ShouldWrite(errorLog, verbose, own, level, text);
                if (got != want)
                {
                    all = false;
                    Check("log filter: errorLog " + errorLog + ", verbose " + verbose + ", own " + own + ", level " + level
                          + ", text '" + text + "'", false, "got " + got);
                }
                combos++;
            }
            Check("log filter: all " + combos + " combinations as the rule says", all && combos == 2 * 2 * 2 * Levels.Length * Texts.Length, "");

            // The cheap test before the text is read: true exactly when some text would be written.
            bool might = true;
            for (int mask = 0; mask < 64; mask++)
            foreach (bool errorLog in new[] { false, true })
            foreach (bool verbose in new[] { false, true })
            foreach (bool own in new[] { false, true })
            {
                bool any = false;
                foreach (string text in Texts) { if (LogRules.ShouldWrite(errorLog, verbose, own, mask, text)) any = true; }
                bool want = (errorLog || verbose) && (verbose || (mask & 7) != 0);
                bool mw = LogRules.MightWrite(errorLog, verbose, mask);
                if (mw != want || (any && !mw) || mw != LogRules.ShouldWrite(errorLog, verbose, own, mask, "NuclearTrollstav"))
                {
                    might = false;
                    Check("log filter: MightWrite(" + errorLog + ", " + verbose + ", " + mask + "), own " + own, false, "got " + mw);
                }
            }
            Check("log filter: MightWrite is true exactly when some text would be written (all 512 combinations)", might, "");

            // The cases the README names.
            Check("log filter: default (ErrorLog on): the plugin's error goes in", LogRules.ShouldWrite(true, false, true, LogRules.Error, "x"), "");
            Check("log filter: default: the plugin's warning goes in", LogRules.ShouldWrite(true, false, true, LogRules.Warning, "x"), "");
            Check("log filter: default: the plugin's info line stays out", !LogRules.ShouldWrite(true, false, true, LogRules.Info, "x"), "");
            Check("log filter: default: the plugin's debug line stays out", !LogRules.ShouldWrite(true, false, true, LogRules.Debug, "x"), "");
            Check("log filter: default: another mod's error stays out", !LogRules.ShouldWrite(true, false, false, LogRules.Error, "Some other mod failed"), "");
            Check("log filter: default: an exception naming the plugin goes in",
                LogRules.ShouldWrite(true, false, false, LogRules.Error, "NullReferenceException\nStack trace:\nNuclearTrollstav.Alerts.Tick ()"), "");
            Check("log filter: default: another source's info naming the plugin stays out", !LogRules.ShouldWrite(true, false, false, LogRules.Info, "Loading [NuclearTrollstav 1.1.0]"), "");
            Check("log filter: VerboseLog: the plugin's debug line goes in", LogRules.ShouldWrite(true, true, true, LogRules.Debug, "x"), "");
            Check("log filter: VerboseLog with ErrorLog off still takes errors", LogRules.ShouldWrite(false, true, true, LogRules.Error, "x"), "");
            Check("log filter: VerboseLog: another source's info naming the plugin goes in", LogRules.ShouldWrite(false, true, false, LogRules.Info, "Loading [NuclearTrollstav 1.1.0]"), "");
            Check("log filter: VerboseLog: another mod's line not naming it stays out", !LogRules.ShouldWrite(true, true, false, LogRules.Error, "Some other mod failed"), "");
            Check("log filter: both off: not even an error", !LogRules.ShouldWrite(false, false, true, LogRules.Fatal, "x"), "");
            Check("log filter: problems are Fatal, Error and Warning only",
                LogRules.IsProblem(LogRules.Fatal) && LogRules.IsProblem(LogRules.Error) && LogRules.IsProblem(LogRules.Warning)
                && !LogRules.IsProblem(LogRules.Message) && !LogRules.IsProblem(LogRules.Info) && !LogRules.IsProblem(LogRules.Debug)
                && !LogRules.IsProblem(0), "");
        }

        private static void LogFormatTests()
        {
            DateTime t = new DateTime(2026, 10, 2, 9, 5, 7, 42);
            string[] one = LogRules.FormatEntry(t, LogRules.Warning, "NuclearTrollstav", "Arm sound: no file at x");
            Check("log format: one line", one.Length == 1, "lines " + one.Length);
            Check("log format: time, level, source, text", one[0] == "09:05:07.042 [Warning:NuclearTrollstav] Arm sound: no file at x", one[0]);

            string[] many = LogRules.FormatEntry(t, LogRules.Error, "Unity Log", "Boom\r\nStack trace:\r\n  at A\r\n");
            Check("log format: a stack trace keeps its lines, without the trailing break", many.Length == 3, "lines " + many.Length);
            Check("log format: the first line starts with the time", many.Length == 3 && many[0] == "09:05:07.042 [Error:Unity Log] Boom", many.Length > 0 ? many[0] : "");
            Check("log format: the lines after it are indented", many.Length == 3 && many[1] == "    Stack trace:" && many[2] == "      at A", "");
            Check("log format: a lone carriage return breaks a line too", LogRules.FormatEntry(t, LogRules.Info, "s", "a\rb").Length == 2, "");
            Check("log format: no text, no source", LogRules.FormatEntry(t, LogRules.Debug, null, null)[0] == "09:05:07.042 [Debug:?] ", "");

            // Every flag combination: the most severe name, in the order Fatal, Error, Warning, Message, Info, Debug.
            string[] order = { "Fatal", "Error", "Warning", "Message", "Info", "Debug" };
            bool names = true;
            for (int mask = 0; mask < 64; mask++)
            {
                string want = "Log";
                for (int b = 0; b < 6; b++) { if ((mask & (1 << b)) != 0) { want = order[b]; break; } }
                if (LogRules.LevelName(mask) != want) { names = false; Check("log format: level name of " + mask, false, LogRules.LevelName(mask) + ", wanted " + want); }
            }
            Check("log format: the level name of all 64 flag combinations", names, "");

            string header = LogRules.SessionHeader(t, "1.1.0", "1.0.16", true, false);
            Check("log format: the session header", header == "==== 2026-10-02 09:05:07 - NuclearTrollstav 1.1.0, Valheim 1.0.16 - ErrorLog on, VerboseLog off", header);
            Check("log format: an unknown game version", LogRules.SessionHeader(t, "1.1.0", null, false, true).Contains("Valheim ? - ErrorLog off, VerboseLog on"), "");
            Check("log format: the two limit notes",
                LogRules.LimitNote(false, 9998) == "==== 9998 lines written this session: no more until the game restarts, except warnings and errors."
                && LogRules.LimitNote(true, 2000) == "==== 2000 lines of warnings and errors written this session: no more of them until the game restarts."
                && LogRules.LimitNote(true, 1) == "==== 1 line of warnings and errors written this session: no more of them until the game restarts.", "");

            // The numbers the README states.
            Check("log format: renamed at 1 MiB", LogRules.RotateAtBytes == 1048576 && !LogRules.ShouldRotate(1048575) && LogRules.ShouldRotate(1048576), "");
            Check("log format: 10,000 lines a session, and 2,000 of warnings and errors besides",
                LogRules.MaxLinesPerSession == 10000 && LogRules.MaxProblemLinesPerSession == 2000, "");
            Check("log format: up to five copies of the game", LogFile.MaxCopies == 5, "");
        }

        private static void LogFileTests()
        {
            string dir = Path.Combine(Path.GetTempPath(), "nt-logtests-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            try
            {
                string path = Path.Combine(dir, LogFile.FileName);
                string old = Path.Combine(dir, LogFile.OldFileName);

                LogFile f = new LogFile(dir, 5, 3);
                Check("log file: the path is the folder plus NuclearTrollstav.log", f.FilePath == path, f.FilePath);
                Check("log file: not open before Open", !f.IsOpen && !File.Exists(path), "");
                Check("log file: a write before Open is not written", !f.Write(new[] { "early" }, false), "");
                Check("log file: opens", f.Open("H1") && f.IsOpen, f.FailReason);
                Check("log file: a second Open is a no-op", f.Open("H1 again"), "");
                Check("log file: writes an entry", f.Write(new[] { "a" }, false), "");
                Check("log file: readable while open, every line already on disk", ReadShared(path) == "H1\na\n", Show(ReadShared(path)));
                Check("log file: no write of nothing", !f.Write(new string[0], false) && !f.Write(null, false), "");
                Check("log file: a two-line entry", f.Write(new[] { "b", "    b2" }, false), "");
                Check("log file: line 4 of 5", f.Write(new[] { "c" }, false), "");
                Check("log file: a 3-line entry over the limit is refused", !f.Write(new[] { "x1", "x2", "x3" }, false), "");
                Check("log file: after the note, even a line that would fit is refused", !f.Write(new[] { "z" }, false), "");
                Check("log file: warnings and errors have their own allowance", f.Write(new[] { "p1" }, true) && f.Write(new[] { "p2", "p3" }, true), "");
                Check("log file: until it is used up too", !f.Write(new[] { "p4" }, true) && !f.Write(new[] { "p5" }, true), "");
                string text = ReadShared(path);
                string[] lines = text.Split('\n');
                Check("log file: one note for each allowance, with the lines really written",
                    Count(text, "lines written this session") == 1 && text.Contains("==== 4 lines written this session")
                    && Count(text, "lines of warnings and errors written") == 1 && text.Contains("==== 3 lines of warnings and errors"), Show(text));
                Check("log file: nothing refused got in", Array.IndexOf(lines, "x1") < 0 && Array.IndexOf(lines, "z") < 0
                      && Array.IndexOf(lines, "p4") < 0 && Array.IndexOf(lines, "p5") < 0 && Array.IndexOf(lines, "c") > 0, Show(text));
                f.Close();
                Check("log file: closed", !f.IsOpen, "");
                Check("log file: once closed it stays closed (a line during shutdown)", !f.Open("late") && !f.Write(new[] { "late" }, true), "");
                Check("log file: and nothing was written after Close", !ReadShared(path).Contains("late"), "");
                f.Close();   // twice is fine

                LogFile g = new LogFile(dir, 5, 3);
                Check("log file: the next session opens", g.Open("H2"), g.FailReason);
                Check("log file: and appends to the same file", g.Write(new[] { "second session" }, false), "");
                g.Close();
                text = ReadShared(path);
                Check("log file: both sessions kept, in order", text.IndexOf("H1", StringComparison.Ordinal) == 0
                      && text.IndexOf("H2", StringComparison.Ordinal) > text.IndexOf("p3", StringComparison.Ordinal)
                      && text.TrimEnd().EndsWith("second session", StringComparison.Ordinal), Show(text));
                Check("log file: no BOM", File.ReadAllBytes(path)[0] == (byte)'H', "");

                // The plugin's own limits: 10,000 lines, then only warnings and errors.
                string dirBig = Path.Combine(dir, "big");
                Directory.CreateDirectory(dirBig);
                LogFile big = new LogFile(dirBig);
                big.Open("HB");
                bool allIn = true;
                for (int i = 0; i < 10000; i++) { if (!big.Write(new[] { "line" }, false)) { allIn = false; break; } }
                Check("log file: the plugin's file takes 10,000 lines", allIn, "");
                Check("log file: and not the 10,001st", !big.Write(new[] { "line" }, false), "");
                Check("log file: but still an error after them", big.Write(new[] { "an error" }, true), "");
                bool problemsIn = true;
                for (int i = 1; i < 2000; i++) { if (!big.Write(new[] { "an error" }, true)) { problemsIn = false; break; } }
                Check("log file: the plugin's file takes 2,000 lines of warnings and errors", problemsIn, "");
                Check("log file: and not the 2,001st", !big.Write(new[] { "an error" }, true), "");
                big.Close();
                string bigText = ReadShared(Path.Combine(dirBig, LogFile.FileName));
                Check("log file: one note at 10,000, one at 2,000", Count(bigText, "==== 10000 lines written this session") == 1
                      && Count(bigText, "==== 2000 lines of warnings and errors") == 1, "");

                // A note gives the lines really written, not the limit.
                string dirNote = Path.Combine(dir, "note");
                Directory.CreateDirectory(dirNote);
                LogFile n = new LogFile(dirNote, 5, 3);
                n.Open("HN");
                n.Write(new[] { "p1" }, true);
                Check("log file: a 3-line error with room for 2 is refused", !n.Write(new[] { "e1", "e2", "e3" }, true), "");
                n.Write(new[] { "o1", "o2" }, false);
                Check("log file: a 4-line entry with room for 3 is refused", !n.Write(new[] { "a", "b", "c", "d" }, false), "");
                n.Close();
                string noteText = ReadShared(Path.Combine(dirNote, LogFile.FileName));
                Check("log file: each note counts what was written", noteText.Contains("==== 1 line of warnings and errors written")
                      && noteText.Contains("==== 2 lines written this session"), Show(noteText));

                // Closed before it was ever opened: still closed (the plugin shut down before its first line).
                LogFile early = new LogFile(dirNote, 5, 3);
                early.Close();
                Check("log file: closed before opening, it never opens", !early.Open("late") && !early.Write(new[] { "late" }, true), "");

                // At a session's start, a file of 1 MiB or more becomes the .old one (replacing the one before).
                File.WriteAllText(old, "an older old file");
                File.WriteAllText(path, new string('x', (int)LogRules.RotateAtBytes));
                LogFile h = new LogFile(dir, 5, 3);
                Check("log file: opens after a big file", h.Open("H3"), h.FailReason);
                h.Write(new[] { "fresh" }, false);
                h.Close();
                Check("log file: the big file became the .old one", File.Exists(old) && new FileInfo(old).Length == LogRules.RotateAtBytes, File.Exists(old) ? new FileInfo(old).Length.ToString() : "no .old");
                Check("log file: the new file starts with this session", ReadShared(path).StartsWith("H3", StringComparison.Ordinal), Show(ReadShared(path)));
                LogFile h2 = new LogFile(dir, 5, 3);
                h2.Open("H4");
                h2.Close();
                Check("log file: a small file is not renamed", ReadShared(path).Contains("H3") && ReadShared(path).Contains("H4"), Show(ReadShared(path)));

                // A big file that another program has open (a viewer, or another copy of the game) is left as it is:
                // the .old one is never deleted for a rename that cannot happen.
                File.WriteAllText(old, "the archive");
                File.WriteAllText(path, new string('y', (int)LogRules.RotateAtBytes));
                using (FileStream viewer = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                {
                    LogFile v = new LogFile(dir, 5, 3);
                    Check("log file: opens beside a viewer", v.Open("H5"), v.FailReason);
                    v.Close();
                }
                Check("log file: a held big file keeps the archive", File.Exists(old) && File.ReadAllText(old) == "the archive", "");
                Check("log file: and is appended to, not renamed", new FileInfo(path).Length > LogRules.RotateAtBytes, "");
                using (FileStream viewer = new FileStream(old, FileMode.Open, FileAccess.Read, FileShare.Read))
                {
                    LogFile v = new LogFile(dir, 5, 3);
                    Check("log file: opens while the .old one is held", v.Open("H6"), v.FailReason);
                    v.Close();
                }
                Check("log file: a held .old one is kept, and the big file stays", File.Exists(old) && File.ReadAllText(old) == "the archive" && File.Exists(path) && new FileInfo(path).Length > LogRules.RotateAtBytes, "");
                File.Delete(path);

                // Two copies of the game at once (two clients on one machine, to try multiplayer): the second writes
                // its own numbered file, so neither overwrites the other's lines; at most five.
                LogFile p = new LogFile(dir, 50, 50);
                LogFile q = new LogFile(dir, 50, 50);
                Check("log file: two copies both open", p.Open("P") && q.Open("Q"), p.FailReason + " " + q.FailReason);
                Check("log file: the first copy keeps NuclearTrollstav.log", p.FilePath == path, p.FilePath);
                Check("log file: the second copy takes NuclearTrollstav.2.log", q.FilePath == Path.Combine(dir, "NuclearTrollstav.2.log"), q.FilePath);
                Check("log file: both write", p.Write(new[] { "from p" }, false) && q.Write(new[] { "from q" }, false), "");
                Check("log file: the first file is readable while both run", ReadShared(path).Contains("from p"), "");
                List<LogFile> more = new List<LogFile>();
                for (int i = 3; i <= 5; i++)
                {
                    LogFile c = new LogFile(dir, 50, 50);
                    Check("log file: copy " + i + " takes NuclearTrollstav." + i + ".log", c.Open("C") && c.FilePath == Path.Combine(dir, "NuclearTrollstav." + i + ".log"), c.FilePath);
                    more.Add(c);
                }
                LogFile sixth = new LogFile(dir, 50, 50);
                Check("log file: a sixth copy gets no file", !sixth.Open("S") && sixth.Failed, sixth.FailReason ?? "");
                foreach (LogFile c in more) c.Close();
                p.Close();
                q.Close();
                text = ReadShared(path);
                string text2 = ReadShared(q.FilePath);
                Check("log file: each copy's lines are whole, in its own file", text.Contains("P\nfrom p\n") && !text.Contains("from q")
                      && text2 == "Q\nfrom q\n", Show(text) + " / " + Show(text2));
                LogFile r = new LogFile(dir, 50, 50);
                Check("log file: once the first copy is closed, the next game takes NuclearTrollstav.log again", r.Open("R") && r.FilePath == path, r.FilePath);
                r.Close();
                Check("log file: the names", LogFile.NameOf(1, false) == LogFile.FileName && LogFile.NameOf(1, true) == LogFile.OldFileName
                      && LogFile.NameOf(3, true) == "NuclearTrollstav.3.old.log", "");

                // A folder that cannot be written: no throw, it turns itself off, says why, and stays off.
                string missing = Path.Combine(dir, "no such folder");
                LogFile bad = new LogFile(missing, 5, 3);
                bool opened = true;
                bool threw = false;
                try { opened = bad.Open("X"); } catch (Exception) { threw = true; }
                Check("log file: a missing folder does not throw", !threw, "");
                Check("log file: a missing folder fails to open", !opened && bad.Failed && !string.IsNullOrEmpty(bad.FailReason), bad.FailReason ?? "");
                Directory.CreateDirectory(missing);
                Check("log file: and stays off even once the folder exists", !bad.Open("X") && !bad.Write(new[] { "y" }, true)
                      && !File.Exists(Path.Combine(missing, LogFile.FileName)), "");
                string cwdFile = Path.Combine(Directory.GetCurrentDirectory(), LogFile.FileName);
                bool cwdBefore = File.Exists(cwdFile);
                foreach (string folder in new[] { null, "" })
                {
                    LogFile none = new LogFile(folder, 5, 3);
                    threw = false;
                    opened = true;
                    try { opened = none.Open("X"); none.Write(new[] { "y" }, true); none.Close(); } catch (Exception) { threw = true; }
                    Check("log file: no folder (" + (folder == null ? "null" : "empty") + ") does not throw", !threw, "");
                    Check("log file: no folder fails to open, never the working folder", !opened && none.Failed, none.FailReason ?? "");
                }
                Check("log file: nothing written to the working folder", File.Exists(cwdFile) == cwdBefore, cwdFile);
            }
            finally
            {
                try { Directory.Delete(dir, true); } catch (Exception) { }
            }
        }

        private static void IsWaitingTests()
        {
            AlertScheduler s = new AlertScheduler();
            Check("is waiting: nothing at first", !s.IsWaiting(AlertKind.Arm) && !s.IsWaiting(AlertKind.Launch), "");
            s.Offer(AlertKind.Arm, 0.0, Cooldown);
            Check("is waiting: the arm alert accepted", s.IsWaiting(AlertKind.Arm) && !s.IsWaiting(AlertKind.Launch), "");
            s.Offer(AlertKind.Launch, 0.1, Cooldown);
            Check("is waiting: both", s.IsWaiting(AlertKind.Arm) && s.IsWaiting(AlertKind.Launch), "");
            s.Tick(0.2, false, Gap, true, MaxWait);
            Check("is waiting: the arm alert handed out, the launch still waits", !s.IsWaiting(AlertKind.Arm) && s.IsWaiting(AlertKind.Launch), "");
            s.DropWaiting();
            Check("is waiting: dropped", !s.IsWaiting(AlertKind.Arm) && !s.IsWaiting(AlertKind.Launch), "");
            Check("is waiting: an invalid kind", !s.IsWaiting((AlertKind)7), "");
        }

        /// <summary>Reads the file the way a player's editor would while the game writes it.</summary>
        private static string ReadShared(string path)
        {
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (StreamReader r = new StreamReader(fs, new UTF8Encoding(false)))
            {
                return r.ReadToEnd().Replace("\r\n", "\n");
            }
        }

        private static int Count(string text, string part)
        {
            int n = 0;
            for (int at = text.IndexOf(part, StringComparison.Ordinal); at >= 0; at = text.IndexOf(part, at + part.Length, StringComparison.Ordinal)) n++;
            return n;
        }

        private static string Show(string text)
        {
            return text.Length > 300 ? text.Substring(0, 300) + "..." : text.Replace("\n", "|");
        }
    }
}
