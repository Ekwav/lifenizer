using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using lifenizer.DataModels;
using Newtonsoft.Json;

namespace lifenizer.Search {
    /// <summary>
    /// Agrep is file based and always searches all files
    /// </summary>
    public class FileBasedSearch : ISearcher {
        private string path;
        private Random random = new Random();

        /// <summary>
        /// Generates a new Agrep search
        /// </summary>
        /// <param name="storagePath">Persistant Storage path to save data in</param>
        public FileBasedSearch (string storagePath) {
            this.path = storagePath;
            Directory.CreateDirectory(storagePath);
        }

        public IEnumerable<Match> FindMatches (string searchTerm, int maxDifference = 1)
        {
            JsonSerializer serializer = new JsonSerializer();
            return FindFiles(
                GetFileNames(path),
                (line) => line.IndexOf(searchTerm) >= 0)
            .Select(file=>new Match(JsonConvert.DeserializeObject<Conversation>(File.ReadAllText(file))));
        }



        public void IndexSingle (Conversation conversation) {
            var filePath = Path.Combine(path,$"{DateTime.Now.ToString()}.{random.Next(1000)}.ls");
            File.WriteAllText(filePath,JsonConvert.SerializeObject(conversation));
        }

        public void IndexBatch (IEnumerable<Conversation> batch) {
            foreach (var item in batch)
            {
                IndexSingle(item);
            }
        }

        public static IEnumerable<string> FindFiles (IEnumerable<string> fileNames, Func<string, bool> predicate) {
            return fileNames.Select (fileName => {
                    using (var sr = new StreamReader (fileName)) {
                        var line = string.Empty;
                        while ((line = sr.ReadLine ()) != null) {
                            if (predicate (line)) {
                                return fileName;
                            }
                        }
                    }
                    return null;
                })
                .Where (line => !string.IsNullOrEmpty (line));
        }

        public static IEnumerable<string> GetFileNames (string path) {
            return
            Directory.EnumerateFiles (path);
        }

    }

}