using System;
using System.Collections.Generic;
using System.IO;
using lifenizer.Converters;
using lifenizer.DataModels;
using lifenizer.Importers;
using Lucene.Net.Analysis.Standard;
using Lucene.Net.Codecs;
using Lucene.Net.Configuration;
using Lucene.Net.Documents;
using Lucene.Net.Index;
using Lucene.Net.Search;
using Lucene.Net.Store;
using Lucene.Net.Util;
using ManyConsole;

namespace lifenizer {

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
        public IImporter Importer { get; }
        public IConverter Converter { get; }
        public IServiceProvider Search { get; }

        public void Add (string args) {
            var path = Importer.Import (args);
        }
    }

    /// <summary>
    /// Persists files and documents 
    /// </summary>
    public interface IDocumentStore {

    }

    public class LucenceSearch {
        public void Index (Conversation conversation) {
            var AppLuceneVersion = LuceneVersion.LUCENE_48;
            var indexLocation = @"/home/ekwav/dev/lucence/index";
            var dir = FSDirectory.Open (indexLocation);

            //create an analyzer to process the text
            var analyzer = new StandardAnalyzer (AppLuceneVersion);

            //create an index writer
            var indexConfig = new IndexWriterConfig (AppLuceneVersion, analyzer);
            var writer = new IndexWriter (dir, indexConfig);

            var d = new Document {
                new StringField("name","/c/noch/eins",Field.Store.YES),
                new TextField ("text", "Guten Morgen herr von und zu sowieso IHK", Field.Store.YES)
            };
            var d2 = new Document {
                new StringField("name","/c/oder/ijajadja",Field.Store.YES),
                new TextField ("text", "Durchaus möglichn  von dem herrn von der IHK", Field.Store.YES)
            };

            //writer.AddDocument (d);
            //writer.AddDocument (d2);
            writer.Flush (triggerMerge: false, applyAllDeletes: false);
            var phrase = new FuzzyQuery (new Term("text","ikh"),2);
            //phrase.Add (new Term ("text","morgen"));
            //phrase.Add (new Term ("text", "herr")); DirectoryReader.Open(dir));//
            writer.Dispose();
            var searcher = new IndexSearcher(DirectoryReader.Open(dir));//writer.GetReader(applyAllDeletes: true));
            var hits = searcher.Search(phrase, 20 /* top 20 */).ScoreDocs;
            foreach (var hit in hits)
            {
                var foundDoc = searcher.Doc(hit.Doc);
                var score = hit.Score;
                foundDoc.Get("name");
                foundDoc.Get("favoritePhrase");
            }
        }
    }

}