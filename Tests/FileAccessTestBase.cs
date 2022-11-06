using System;
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
            tempFolder = RandomTempFolderPath();
            Directory.CreateDirectory(tempFolder);
        }

        protected string RandomTempFolderPath()
        {
            return Path.Combine(Path.GetTempPath(), "lifenizer", "test", System.DateTime.Now.Ticks.ToString() + Random.Shared.Next(100000));
        }
    }
}