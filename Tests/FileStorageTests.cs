using System.IO;
using System.Linq;
using lifenizer;
using lifenizer.DataModels;
using lifenizer.Storage;
using Moq;
using NUnit.Framework;

namespace Tests
{
    public class FileStorageTests : FileAccessTestBase
    {
        protected IStorage storage;
        protected Conversation conversation;

        string path;
        byte[] blob;

        [TearDown]
        public void Teardown()
        {
            Directory.Delete(tempFolder,true);
        }

        [SetUp]
        public void SetupStorage()
        {
            conversation = new Conversation(){OriginalUrl = "test"};
            storage = new LocalFileStorage(tempFolder);
            blob = new byte[]{123,45,67};
            path = Path.Combine(tempFolder,"importedfile");
            File.WriteAllBytes(path,blob);
        }



        [Test]
        public void Store()
        {
            storage.SaveFile(Path.Combine(tempFolder,"importedfile"),conversation);
        }

        [Test]
        public void StoreAndRetrieveConversation()
        {
            var id = storage.SaveFile(Path.Combine(tempFolder,"importedfile"),conversation);
            var retrieved = storage.GetConversation(id);
            Assert.AreEqual(conversation,retrieved);
        }

        [Test]
        public void StoreAndRetrieveFile()
        {
            var id = storage.SaveFile(path,conversation);
            var bytes = new byte[blob.Length];
            storage.GetFile(id).Read(bytes,0,blob.Length);
            Assert.AreEqual(blob,bytes);
        }



    }
}