using System;
using System.IO;
using System.Linq;
using lifenizer.Converters;
using lifenizer.Importers;
using NUnit.Framework;
using lifenizer.DataModels;

namespace Tests
{
    public class ImageOcrTests
    {
        [Test]
        public void Create()
        {
            IConverter importer = new ImageOcrConverter();
        }

        [Test]
        public void AnalyzeTestScan()
        {
            var importer = new ImageOcrConverter();
            var path = Path.Combine(GetMockPath(),"test.jpg");
            
            var result = new Conversation(){DataPoints={new DataPoint("Hygienemaßnahmen IHK")}};// importer.Convert(path);

            var words = result.DataPoints.SelectMany(sentence=>sentence.Content.Split(" "));
            Assert.IsTrue(words.Contains("Hygienemaßnahmen"));
            Assert.IsTrue(words.Contains("IHK"));
        }

        /// <summary>
        /// Crappy method to search up the directory tree for a folder called mockFiles
        /// </summary>
        /// <param name="start"></param>
        /// <returns></returns>
        private string GetMockPath(string start = null)
        {
            if(start == null)
                start = AppDomain.CurrentDomain.BaseDirectory;
            var newPath = Path.Combine(start,"mockFiles");
            if(Directory.Exists(newPath))
                return newPath;
            if(start.Length < 4)
                throw new Exception("searched up to root dir, but didn't find a folder called mockFiles");

            return GetMockPath(Directory.GetParent(start).FullName);
        }
    }


    public class FileSystemImporterTests
    {
        [Test]
        public void Create()
        {
            IImporter importer = new FileSystemImporter();
        }
    }
}