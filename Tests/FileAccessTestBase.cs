using System.IO;
using lifenizer.Storage;
using NUnit.Framework;

namespace Tests
{
    public class FileAccessTestBase
    {
        protected string tempFolder;
        [SetUp]
        public void Setup()
        {
            tempFolder = TempFolderPath();
        }

        private static string TempFolderPath()
        {
            var path = Path.Combine(Path.GetTempPath(),"lifenizer","test",System.DateTime.Now.Ticks.ToString());
            Directory.CreateDirectory(path);
            return path;
        }
    }
}