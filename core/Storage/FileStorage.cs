using System.IO;
using lifenizer.DataModels;

namespace lifenizer.Storage
{
    
    public interface IStorage
    {
        /// <summary>
        /// Returns a unique url for this file
        /// </summary>
        /// <param name="localPath">The local binary to be stored</param>
        /// <param name="conversation">The accociated conversation derived from the binary</param>
        /// <returns>An url to retrieve the stored data</returns>
        string SaveFile(string localPath, Conversation conversation);
        /// <summary>
        /// Gets the Conversation metadata for a specific imported Artifact
        /// </summary>
        /// <param name="url"></param>
        /// <returns></returns>
        Conversation GetConversation(string url);
        /// <summary>
        /// Gets a stream to the original imported artifact
        /// </summary>
        /// <param name="url"></param>
        /// <returns></returns>
        Stream GetFile(string url);

    }

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
        /// <summary>
        /// Gets the Conversation metadata for a specific imported Artifact
        /// </summary>
        /// <param name="url"></param>
        /// <returns></returns>
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