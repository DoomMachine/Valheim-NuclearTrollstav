using System;
using System.Globalization;
using System.IO;
using System.Text;

namespace NuclearTrollstav
{
    /// <summary>
    /// Which log lines go into the plugin's own log file, and how they look. No Unity or BepInEx here: tested in
    /// tests\. Levels are BepInEx's LogLevel flags (Fatal 1, Error 2, Warning 4, Message 8, Info 16, Debug 32).
    /// </summary>
    public static class LogRules
    {
        public const int Fatal = 1, Error = 2, Warning = 4, Message = 8, Info = 16, Debug = 32;

        /// <summary>A line from another source is the plugin's when its text names the plugin (an exception's stack).</summary>
        public const string Mention = "NuclearTrollstav";

        public const long RotateAtBytes = 1024 * 1024;        // at start, a file this big is renamed to the .old name
        public const int MaxLinesPerSession = 10000;          // lines other than warnings and errors, per session
        public const int MaxProblemLinesPerSession = 2000;    // warnings and errors, counted apart, so verbose lines cannot crowd them out

        /// <summary>A warning, an error or worse.</summary>
        public static bool IsProblem(int level)
        {
            return (level & (Fatal | Error | Warning)) != 0;
        }

        /// <summary>
        /// Whether a log line goes into the file. ErrorLog: the plugin's own warnings and errors. VerboseLog: every line
        /// the plugin writes, errors included, whatever ErrorLog says. Either one: another source's line that names the
        /// plugin, at the same levels.
        /// </summary>
        public static bool ShouldWrite(bool errorLog, bool verboseLog, bool ownSource, int level, string text)
        {
            if (!errorLog && !verboseLog) return false;
            if (!ownSource && (text == null || text.IndexOf(Mention, StringComparison.OrdinalIgnoreCase) < 0)) return false;
            return verboseLog || IsProblem(level);
        }

        /// <summary>
        /// The cheap test before a line's text is read (most lines - info lines - stop here): true exactly when some text
        /// would be written at this level. Whose line it is only decides whether the text must name the plugin.
        /// </summary>
        public static bool MightWrite(bool errorLog, bool verboseLog, int level)
        {
            return (errorLog || verboseLog) && (verboseLog || IsProblem(level));
        }

        /// <summary>The level's name, the most severe one when several flags are set.</summary>
        public static string LevelName(int level)
        {
            if ((level & Fatal) != 0) return "Fatal";
            if ((level & Error) != 0) return "Error";
            if ((level & Warning) != 0) return "Warning";
            if ((level & Message) != 0) return "Message";
            if ((level & Info) != 0) return "Info";
            if ((level & Debug) != 0) return "Debug";
            return "Log";
        }

        /// <summary>
        /// One log entry as file lines: the first starts with the time, the level and the source; the lines after it
        /// (a stack trace) are indented, so every entry starts with its time.
        /// </summary>
        public static string[] FormatEntry(DateTime time, int level, string source, string text)
        {
            string body = (text ?? "").Replace("\r\n", "\n").Replace('\r', '\n').TrimEnd('\n');
            string[] lines = body.Split('\n');
            lines[0] = time.ToString("HH:mm:ss.fff", CultureInfo.InvariantCulture) + " [" + LevelName(level) + ":"
                       + (source ?? "?") + "] " + lines[0];
            for (int i = 1; i < lines.Length; i++) lines[i] = "    " + lines[i];
            return lines;
        }

        /// <summary>The line that opens the file in each game session: when it was opened, and the settings then.</summary>
        public static string SessionHeader(DateTime time, string pluginVersion, string gameVersion, bool errorLog, bool verboseLog)
        {
            return "==== " + time.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) + " - NuclearTrollstav "
                   + pluginVersion + ", Valheim " + (gameVersion ?? "?") + " - ErrorLog " + OnOff(errorLog)
                   + ", VerboseLog " + OnOff(verboseLog);
        }

        /// <summary>The note written once when one of the two allowances is used up.</summary>
        public static string LimitNote(bool problems, int written)
        {
            string lines = written == 1 ? " line" : " lines";
            return problems
                ? "==== " + written + lines + " of warnings and errors written this session: no more of them until the game restarts."
                : "==== " + written + lines + " written this session: no more until the game restarts, except warnings and errors.";
        }

        public static bool ShouldRotate(long size)
        {
            return size >= RotateAtBytes;
        }

        private static string OnOff(bool b)
        {
            return b ? "on" : "off";
        }
    }

    /// <summary>
    /// The plugin's own log file. Kept across game sessions (the game rewrites its own logs at every start): each
    /// session appends, opening with a header line; at the session's start a file of LogRules.RotateAtBytes or more is
    /// renamed to the .old name, replacing the one before - unless another program has it open, when it is left as it
    /// is. A session writes at most LogRules.MaxLinesPerSession lines other than warnings and errors, and
    /// LogRules.MaxProblemLinesPerSession lines of warnings and errors besides; each allowance, once used up, gets one
    /// note and nothing more. One game holds the file for writing (others may read it): a second copy of the game running
    /// at the same time writes NuclearTrollstav.2.log instead, and so on up to MaxCopies - as BepInEx does with
    /// LogOutput.log. Safe to call from any thread, and it never throws: a file it cannot write turns it off, and
    /// FailReason says why. Once closed, it stays closed.
    /// </summary>
    public sealed class LogFile
    {
        public const string FileName = "NuclearTrollstav.log";
        public const string OldFileName = "NuclearTrollstav.old.log";
        public const int MaxCopies = 5;

        private readonly object _lock = new object();
        private readonly string _folder;
        private readonly int _maxLines;
        private readonly int _maxProblemLines;
        private string _path;
        private StreamWriter _writer;
        private bool _failed;
        private bool _closed;
        private string _failReason;
        private int _lines;
        private int _problemLines;
        private bool _full;
        private bool _problemsFull;

        public LogFile(string folder) : this(folder, LogRules.MaxLinesPerSession, LogRules.MaxProblemLinesPerSession) { }

        public LogFile(string folder, int maxLines, int maxProblemLines)
        {
            _folder = folder ?? "";
            _path = Path.Combine(_folder, FileName);
            _maxLines = maxLines;
            _maxProblemLines = maxProblemLines;
        }

        /// <summary>The file written: NuclearTrollstav.log, or the numbered one a second copy of the game took.</summary>
        public string FilePath { get { lock (_lock) { return _path; } } }

        public bool IsOpen { get { lock (_lock) { return _writer != null; } } }

        public bool Failed { get { lock (_lock) { return _failed; } } }

        public string FailReason { get { lock (_lock) { return _failReason; } } }

        /// <summary>The name of copy n's file (1: NuclearTrollstav.log), and of its .old one.</summary>
        public static string NameOf(int copy, bool old)
        {
            string stem = copy <= 1 ? "NuclearTrollstav" : "NuclearTrollstav." + copy;
            return stem + (old ? ".old.log" : ".log");
        }

        /// <summary>
        /// Opens the file for this session (once) and writes the header. False when it cannot be written, or after
        /// Close (a line that arrives while the game shuts down does not open it again).
        /// </summary>
        public bool Open(string header)
        {
            lock (_lock)
            {
                if (_writer != null) return true;
                if (_failed || _closed) return false;
                if (_folder.Length == 0)
                {
                    Fail(new ArgumentException("no folder given"));   // never the process's working folder
                    return false;
                }
                Exception last = null;
                for (int copy = 1; copy <= MaxCopies; copy++)
                {
                    string path = Path.Combine(_folder, NameOf(copy, false));
                    try
                    {
                        Rotate(path, Path.Combine(_folder, NameOf(copy, true)));
                        FileStream stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read);
                        _path = path;
                        _writer = new StreamWriter(stream, new UTF8Encoding(false));
                        _writer.AutoFlush = true;   // every line is on disk at once: readable while the game runs, kept if it crashes
                        _writer.WriteLine(header ?? "");
                        return true;
                    }
                    catch (Exception e)
                    {
                        last = e;
                        if (!InUse(e)) break;   // a missing folder or no rights: another name will not help
                    }
                }
                Fail(last);
                return false;
            }
        }

        /// <summary>
        /// Writes one entry's lines, against the allowance of its kind (problem: a warning or an error). False when it
        /// was not written (not open, failed, or that allowance used up).
        /// </summary>
        public bool Write(string[] lines, bool problem)
        {
            if (lines == null || lines.Length == 0) return false;
            lock (_lock)
            {
                if (_writer == null || _failed) return false;
                try
                {
                    if (problem)
                    {
                        if (_problemsFull) return false;
                        if (_problemLines + lines.Length > _maxProblemLines)
                        {
                            _problemsFull = true;
                            _writer.WriteLine(LogRules.LimitNote(true, _problemLines));
                            return false;
                        }
                        _problemLines += lines.Length;
                    }
                    else
                    {
                        if (_full) return false;
                        if (_lines + lines.Length > _maxLines)
                        {
                            _full = true;
                            _writer.WriteLine(LogRules.LimitNote(false, _lines));
                            return false;
                        }
                        _lines += lines.Length;
                    }
                    for (int i = 0; i < lines.Length; i++) _writer.WriteLine(lines[i]);
                    return true;
                }
                catch (Exception e)
                {
                    Fail(e);
                    return false;
                }
            }
        }

        public void Close()
        {
            lock (_lock)
            {
                _closed = true;
                StreamWriter w = _writer;
                _writer = null;
                if (w == null) return;
                try { w.Dispose(); } catch (Exception) { }
            }
        }

        /// <summary>
        /// A file grown past the limit becomes the .old one - only when nothing else has it open (another copy of the game,
        /// a viewer). An exclusive handle, sharing only Delete, is held across the delete of the old one and the rename, so
        /// no other program can open the file in between, and a rename that cannot happen never costs the old one.
        /// </summary>
        private static void Rotate(string path, string oldPath)
        {
            try
            {
                FileInfo info = new FileInfo(path);
                if (!info.Exists || !LogRules.ShouldRotate(info.Length)) return;
                using (new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.Delete))   // throws if held; held until moved
                {
                    if (File.Exists(oldPath)) File.Delete(oldPath);
                    File.Move(path, oldPath);
                }
            }
            catch (Exception) { }
        }

        /// <summary>The file is held by another copy of the game (a sharing violation), not missing or forbidden.</summary>
        private static bool InUse(Exception e)
        {
            return e is IOException && !(e is DirectoryNotFoundException) && !(e is FileNotFoundException)
                   && !(e is PathTooLongException) && !(e is DriveNotFoundException);
        }

        private void Fail(Exception e)
        {
            _failed = true;
            _failReason = e == null ? "unknown" : e.GetType().Name + ": " + e.Message;
            StreamWriter w = _writer;
            _writer = null;
            if (w != null)
            {
                try { w.Dispose(); } catch (Exception) { }
            }
        }
    }
}
