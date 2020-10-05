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

        [TearDown]
        public void Teardown()
        {
            Directory.Delete(tempFolder);
        }

        [SetUp]
        public void SetupStorage()
        {
            conversation = new Conversation(){OriginalUrl = "test"};
            storage = new LocalFileStorage(tempFolder);
        }



        [Test]
        public void Store()
        {
            storage.SaveFile("filePath",conversation);
        }

        [Test]
        public void StoreAndRetrieveConversation()
        {
            var id = storage.SaveFile("filePath",conversation);
            var retrieved = storage.GetConversation(id);
            Assert.AreEqual(conversation,retrieved);
        }

        [Test]
        public void StoreAndRetrieveFile()
        {
            var bytes = new byte[]{123,45,67};
            var path = Path.Combine(tempFolder,"importedfile");
            File.WriteAllBytes(path,bytes);
            var id = storage.SaveFile(path,conversation);
            var retrieved = storage.GetFile(id);
            Assert.AreEqual(conversation,retrieved);
        }



    }
}