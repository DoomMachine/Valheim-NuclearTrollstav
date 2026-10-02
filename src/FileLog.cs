using System;
using BepInEx.Logging;

namespace NuclearTrollstav
{
    /// <summary>
    /// Feeds the plugin's own log file (BepInEx\NuclearTrollstav.log, see LogFile).
    /// - From BepInEx's log, as a listener: the plugin's warnings and errors (ErrorLog), every line it logs (VerboseLog),
    ///   and another source's line that names the plugin - an exception from its code that reached the game's own log
    ///   (LogRules.ShouldWrite). BepInEx hands every line to every listener, from whatever thread logged it, with no
    ///   guard against a listener that logs, so the file locks itself, a line logged from in here (the failure warning)
    ///   is not taken in again, and nothing here may throw into the code that logged.
    /// - The VerboseLog lines (Diag), through WriteVerbose: straight into the file, not through BepInEx, whose Unity log
    ///   listener copies every line the plugin logs - Debug lines too - into the game's Player.log.
    /// tools\preflight.ps1 reads the IL of LogEvent, WriteVerbose, OpenIfOn and ReportFailure: keep their shapes.
    /// </summary>
    internal sealed class FileLogListener : ILogListener
    {
        private readonly LogFile _file;
        private readonly ILogSource _own;
        private readonly string _pluginVersion;
        private readonly string _gameVersion;
        private bool _failureReported;

        [ThreadStatic] private static bool _writing;   // set while this thread is in here: a line logged meanwhile is dropped

        public FileLogListener(LogFile file, ILogSource own, string pluginVersion, string gameVersion)
        {
            _file = file;
            _own = own;
            _pluginVersion = pluginVersion;
            _gameVersion = gameVersion;
        }

        public string FilePath { get { return _file.FilePath; } }

        /// <summary>Opens the file now when either setting is on, so a session shows in it even without errors, and says
        /// at once, in BepInEx's log, if it cannot be written.</summary>
        public void OpenIfOn()   // preflight: exact shape
        {
            _writing = true;
            try
            {
                if (Plugin.ErrorLog.Value || Plugin.VerboseLog.Value) _file.Open(Header());
                ReportFailure();
            }
            finally
            {
                _writing = false;
            }
        }

        public void LogEvent(object sender, LogEventArgs eventArgs)
        {
            try
            {
                if (_writing || eventArgs == null) return;
                _writing = true;
                try
                {
                    bool errorLog = Plugin.ErrorLog.Value;
                    bool verbose = Plugin.VerboseLog.Value;
                    int level = (int)eventArgs.Level;
                    bool own = ReferenceEquals(eventArgs.Source, _own);
                    // The cheap test first: most lines are info lines, and their text is never read.
                    if (LogRules.MightWrite(errorLog, verbose, level))
                    {
                        string text = eventArgs.Data != null ? eventArgs.Data.ToString() : "";
                        // preflight: the settings, own and the level feed ShouldWrite, and its result decides the write.
                        if (LogRules.ShouldWrite(errorLog, verbose, own, level, text))
                        {
                            string source = eventArgs.Source != null ? eventArgs.Source.SourceName : "?";
                            if (_file.IsOpen || _file.Open(Header())) _file.Write(LogRules.FormatEntry(DateTime.Now, level, source, text), LogRules.IsProblem(level));
                        }
                    }
                    ReportFailure();   // while _writing is set: its warning cannot come back in here
                }
                finally
                {
                    _writing = false;
                }
            }
            catch (Exception)
            {
                // Never into the code that logged: a listener that throws would break every log call in the game.
            }
        }

        /// <summary>A VerboseLog line (Diag): written to the file only, when VerboseLog is on.</summary>
        public void WriteVerbose(string text)
        {
            try
            {
                if (_writing || !Plugin.VerboseLog.Value) return;
                _writing = true;
                try
                {
                    if (_file.IsOpen || _file.Open(Header())) _file.Write(LogRules.FormatEntry(DateTime.Now, LogRules.Debug, _own.SourceName, text), false);
                    ReportFailure();   // while _writing is set: its warning cannot come back in here
                }
                finally
                {
                    _writing = false;
                }
            }
            catch (Exception)
            {
                // A log line must never stop what the plugin is doing.
            }
        }

        /// <summary>The header for the file opened now: the time, the versions, and the two settings as they are now.</summary>
        private string Header()
        {
            return LogRules.SessionHeader(DateTime.Now, _pluginVersion, _gameVersion, Plugin.ErrorLog.Value, Plugin.VerboseLog.Value);
        }

        /// <summary>Says once, in BepInEx's log, that the file could not be written. Called only while _writing is set.</summary>
        private void ReportFailure()   // preflight: the flag is set before the warning
        {
            if (_failureReported || !_file.Failed) return;
            _failureReported = true;
            Plugin.Log.LogWarning("Could not write " + _file.FilePath + " (" + _file.FailReason + "): the plugin's own log "
                                  + "file is off until the game restarts. Its other lines still go to BepInEx's log.");
        }

        public void Dispose()
        {
            _file.Close();
        }
    }
}
