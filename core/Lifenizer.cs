using System.Collections.Generic;
using System.IO;
using lifenizer.Converters;
using lifenizer.Importers;
using lifenizer.Storage;
using lifenizer.Search;
using lifenizer.DataModels;
using System.Linq;

namespace lifenizer
{
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
        public void Import(string importFilePath,string converterIdentifier = null)
        {
            var tempFilePath = Importer.Import(importFilePath);
            var conversation = ConverterFactory.Instance.ConvertFile(tempFilePath,converterIdentifier);
            var storageId = Storage.SaveFile(tempFilePath,conversation);
            conversation.ImportedUrl = storageId;
            Searcher.IndexSingle(conversation);
        }

        /// <summary>
        /// Search for conversations
        /// </summary>
        /// <param name="query"></param>
        /// <param name="v2"></param>
        public IEnumerable<Conversation> Search(string query, int maxDifference)
        {
            return Searcher.FindMatches(query,maxDifference).Select(Storage.GetConversation);
        }

        public Stream GetFile(string url)
        {
            return Storage.GetFile(url);
        }

    }
}