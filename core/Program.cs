using System;
using System.Collections.Generic;
using System.IO;
using Lucene.Net.Codecs;
using Lucene.Net.Configuration;
using ManyConsole;
using lifenizer.DataModels;

namespace lifenizer
{

    /// <summary>
    /// Entrance
    /// </summary>
    class Program {

        public static string DefaultDataPath { get; set; }

        public static int Main (string[] args) {
            DefaultDataPath = "/media/ekwav/Daten3/dev/lifenizer/data";
            var commands = GetCommands ();

            return ConsoleCommandDispatcher.DispatchCommand (commands, args, Console.Out);
        }

        public static IEnumerable<ConsoleCommand> GetCommands () {
            return ConsoleCommandDispatcher.FindCommandsInSameAssemblyAs (typeof (Program));
        }
    }

    public class PrintFileCommand : ConsoleCommand {
        private const int Success = 0;
        private const int Failure = 2;

        public string FileLocation { get; set; }
        public bool StripCommaCharacter { get; set; }

        public PrintFileCommand () {
            // Register the actual command with a simple (optional) description.
            IsCommand ("print", "Quick print utility.");

            // Add a longer description for the help on that specific command.
            HasLongDescription ("This can be used to quickly read a file's contents " +
                "while optionally stripping out the ',' character.");

            // Required options/flags, append '=' to obtain the required value.
            HasRequiredOption ("f|file=", "The full path of the file.", p => FileLocation = p);

            // Optional options/flags, append ':' to obtain an optional value, or null if not specified.
            HasOption ("s|strip:", "Strips ',' from the file before writing to output.",
                t => StripCommaCharacter = t == null ? true : Convert.ToBoolean (t));
        }

        public override int Run (string[] remainingArguments) {
            try {
                var fileContents = File.ReadAllText (FileLocation);

                if (StripCommaCharacter)
                    fileContents = fileContents.Replace (",", string.Empty);

                Console.Out.WriteLine (fileContents);

                return Success;
            } catch (Exception ex) {
                Console.Error.WriteLine (ex.Message);
                Console.Error.WriteLine (ex.StackTrace);

                return Failure;
            }
        }
    }
    public class EchoCommand : ConsoleCommand {
        public string ToEcho { get; set; }

        public EchoCommand () {
            IsCommand ("echo", "Echo's text");
            HasRequiredOption ("t|text=", "The text to echo back.", t => ToEcho = t);
        }

        public override int Run (string[] remainingArguments) {
            Console.Out.WriteLine (ToEcho);

            return 0;
        }
    }
}