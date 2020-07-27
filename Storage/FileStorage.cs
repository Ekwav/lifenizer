using System.IO;
using lifenizer.DataModels;

namespace lifenizer.Storage
{
    
    public interface IStorage
    {
        /// <summary>
        /// Returns a unique url for this file
        /// </summary>
        /// <param name="localPath"></param>
        /// <returns></returns>
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
    public class LocalFileStorage
    {

    }
}