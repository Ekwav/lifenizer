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

        [TearDown]
        public void Teardown()
        {
            Directory.Delete(tempFolder);
        }



        [Test]
        public void Store()
        {
            storage.SaveFile("filePath",new Conversation());
        }



    }
}