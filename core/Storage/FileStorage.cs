using System.IO;
using lifenizer.DataModels;

namespace lifenizer.Storage
{
    /// <summary>
    /// Abstraction of the Filesystem
    /// </summary>
    public class LocalFileStorage : IStorage
    {
        public string RootPath {get;}

        public LocalFileStorage(string rootPath)
        {
            RootPath = rootPath;
        }

        
        public string SaveFile(string localPath, Conversation conversation)
        {
            return "a";
        }
        
        public Conversation GetConversation(string url)
        {
            return new Conversation();
        }
        /// <summary>
        /// Gets a stream to the original imported artifact
        /// </summary>
        /// <param name="url"></param>
        /// <returns></returns>
        public Stream GetFile(string url)
        {
            return System.IO.File.Open(url,FileMode.Open);
        }
    }
}