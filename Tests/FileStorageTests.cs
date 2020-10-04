using System.IO;
using System.Linq;
using lifenizer;
using lifenizer.DataModels;
using lifenizer.Storage;
using Moq;
using NUnit.Framework;

namespace Tests
{
    public class FileStorageTests
    {
        string tempFolder;
        IStorage storage;
        [SetUp]
        public void Setup()
        {
            tempFolder = TempFolderPath();
            storage = new LocalFileStorage(tempFolder);
        }
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



        private static string TempFolderPath()
        {
            var path = Path.Combine(Path.GetTempPath(),"lifenizer","test",System.DateTime.Now.Ticks.ToString());
            Directory.CreateDirectory(path);
            return path;
        }
    }
}