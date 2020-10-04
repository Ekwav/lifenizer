using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using lifenizer;
using lifenizer.DataModels;
using lifenizer.Search;
using NUnit.Framework;

namespace Tests
{
    public class SearchTests : FileAccessTestBase
    {
        private static DataPoint match = new DataPoint("A wonderful good morning mr John Doe");
        private Conversation conversation;
        private string search = "John";

        private Random r = new Random();

        [SetUp]
        public void Setup()
        {
            conversation = new Conversation(){ImportedUrl = tempFolder,DataPoints= new List<DataPoint>(){match}};
        }

        [Test]
        public void SourceCreation()
        {
            var source = new Match();
        }

        [Test]
        public void SourceCreationPath()
        {
            var source = new Match(conversation);
            Assert.AreEqual(conversation,source.Conversation);
        }

        [Test]
        public void SourceCreationPathAndMatch()
        {
            var source = new Match(conversation,match);
            Assert.AreEqual(match,source.Context);
        }

        [Test]
        public void SearchForMatch()
        {
            var searcher = new FileBasedSearch(tempFolder);
            searcher.FindMatches(search);
        }

        [Test]
        public void AddAndSearchForMatch()
        {
            var tempPath = Path.Combine(Path.GetTempPath(),r.Next().ToString());
            var searcher = new FileBasedSearch(tempPath);
            searcher.IndexSingle(conversation);
            var result = searcher.FindMatches(search).First();
            Assert.AreEqual(conversation,result.Conversation);
        }


        [Test]
        public void IndexFolder()
        {
            ISearcher searcher = new LucenceSearch(tempFolder);
            searcher.IndexBatch(new List<Conversation>(){conversation});
        }

        [Test]
        public void IndexFile()
        {
            ISearcher searcher = new LucenceSearch(tempFolder);
            searcher.IndexSingle(conversation);
        }


        [Test]
        public void Luence()
        {
            var l = new LucenceSearch(tempFolder);
            l.IndexSingle(new Conversation(){ImportedUrl="testUrl"});
        }
    }
}