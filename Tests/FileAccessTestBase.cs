using System.IO;
using lifenizer.Storage;
using NUnit.Framework;

namespace Tests
{
    public class FileAccessTestBase
    {
        protected string tempFolder;
        protected IStorage storage;
        [SetUp]
        public void Setup()
        {
            tempFolder = TempFolderPath();
            storage = new LocalFileStorage(tempFolder);
        }

        private static string TempFolderPath()
        {
            var path = Path.Combine(Path.GetTempPath(),"lifenizer","test",System.DateTime.Now.Ticks.ToString());
            Directory.CreateDirectory(path);
            return path;
        }
    }
}