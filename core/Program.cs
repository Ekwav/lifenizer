using System;
using System.Collections.Generic;
using System.IO;
using lifenizer.Converters;
using lifenizer.Importers;
using Lucene.Net.Codecs;
using Lucene.Net.Configuration;
using ManyConsole;
using lifenizer.DataModels;
using lifenizer.Storage;
using lifenizer.Search;

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

    public class Lifenizer {
        public const string SOURCE_FILE_NAME = "source";

        public IImporter Importer { get; }
        public ISearcher Searcher { get; }
        public IStorage Storage {get;}

        public Lifenizer(IImporter importer, ISearcher searcher, IStorage storage)
        {
            Importer = importer;
            Searcher = searcher;
            Storage = storage;
        }

        /// <summary>
        /// Imports a file under specified path into the system, 
        /// analyzes, converts, stores and indexes it
        /// </summary>
        /// <param name="importFilePath">Path to the file to be imported</param>
        public void Import(string importFilePath)
        {
            var tempFilePath = Importer.Import(importFilePath);
            var conversation = ConverterFactory.Instance.ConvertFile(tempFilePath);
            var storageId = Storage.SaveFile(tempFilePath,conversation);
            conversation.ImportedUrl = storageId;
            Searcher.IndexSingle(conversation);
        }

        /// <summary>
        /// Search for conversations
        /// </summary>
        /// <param name="query"></param>
        /// <param name="v2"></param>
        public IEnumerable<Match> Search(string query, int maxDifference)
        {
            return Searcher.FindMatches(query,maxDifference);
        }

        public Stream GetFile(string url)
        {
            return Storage.GetFile(url);
        }
    }
}