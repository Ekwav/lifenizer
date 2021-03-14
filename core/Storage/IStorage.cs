using System.IO;
using lifenizer.DataModels;

namespace lifenizer.Storage
{
    public interface IStorage
    {
        /// <summary>
        /// Returns a unique url for this file, includes the original file extension (received from <see cref="Conversation.MimeType"/>)
        /// </summary>
        /// <param name="localPath">The local binary to be stored</param>
        /// <param name="conversation">The accociated conversation derived from the binary</param>
        /// <returns>An url to retrieve the stored data</returns>
        string SaveFile(string localPath, Conversation conversation);
        /// <summary>
        /// Gets the Conversation metadata for a specific imported Artifact
        /// </summary>
        /// <param name="url">Unique Identifier previously returned by <see cref="SaveFile"/></param>
        /// <returns>The <see cref="Conversation"/> associated with the file</returns>
        Conversation GetConversation(string url);
        /// <summary>
        /// Gets a stream to the original imported artifact
        /// </summary>
        /// <param name="url">Unique Identifier previously returned by <see cref="SaveFile"/></param>
        /// <returns><see cref="FileStream"/> to the file</returns>
        Stream GetFile(string url);

    }
}