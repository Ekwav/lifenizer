using System.IO;
using lifenizer.DataModels;
using Newtonsoft.Json;
using System;

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
            if(rootPath == null)
                throw new ArgumentException("rootPath has to be set and writeable",nameof(rootPath));
            RootPath = rootPath;
        }

        
        public string SaveFile(string localPath, Conversation conversation)
        {
            var nextId = NewId;
            Directory.CreateDirectory(AbsoluteFilePath(nextId,""));
            MoveFile(localPath,nextId);
            StoreConversation(conversation,nextId);
            return nextId;
        }

        private string NewId
        {
            get {
                return Guid.NewGuid().ToString("N");
            }
        }

        private void StoreConversation(Conversation conversation, string id)
        {
            File.WriteAllText(AbsoluteFilePath(id,"conv"),JsonConvert.SerializeObject(conversation));
        }

        private void MoveFile(string localPath,string id)
        {
            File.Move(localPath,AbsoluteFilePath(id));
        }

        private string AbsoluteFilePath(string identifier,string fileName = "blob")
        {
            return Path.Combine(RootPath,identifier,fileName);
        }
        
        public Conversation GetConversation(string url)
        {
            return JsonConvert.DeserializeObject<Conversation>(File.ReadAllText(AbsoluteFilePath(url,"conv")));
        }
        /// <summary>
        /// Gets a stream to the original imported artifact
        /// </summary>
        /// <param name="url"></param>
        /// <returns></returns>
        public Stream GetFile(string url)
        {
            return System.IO.File.Open(AbsoluteFilePath(url),FileMode.Open);
        }
    }
}