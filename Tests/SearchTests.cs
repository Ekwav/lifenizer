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
        private ISearcher searcher;
        private string docUrl;

        private Random r = new Random();

        [SetUp]
        public void SetupSearch()
        {
            docUrl = Path.Combine(tempFolder,"docUrl");
            conversation = new Conversation(){ImportedUrl = docUrl,DataPoints= new List<DataPoint>(){match}};
            searcher = new LucenceSearch(tempFolder);
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
            searcher.FindMatches(search);
        }

        [Test]
        public void AddAndSearchForMatch()
        {
            var tempPath = Path.Combine(Path.GetTempPath(),r.Next().ToString());
            searcher.IndexSingle(conversation);
            var result = searcher.FindMatches(search).First();
            Assert.AreEqual(conversation.ImportedUrl,result);
        }


        [Test]
        public void IndexFolder()
        {
            searcher.IndexBatch(new List<Conversation>(){conversation});
        }

        [Test]
        public void IndexFile()
        {
            searcher.IndexSingle(conversation);
        }


        [Test]
        public void Luence()
        {
            searcher.IndexSingle(new Conversation(){ImportedUrl="testUrl"});
        }
    }
}