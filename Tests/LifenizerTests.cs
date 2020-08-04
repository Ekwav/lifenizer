using NUnit.Framework;
using lifenizer;
using Moq;
using lifenizer.Importers;
using lifenizer.Storage;
using lifenizer.Search;
using lifenizer.DataModels;
using System.Linq;
using System.IO;
using lifenizer.Converters;

namespace Tests
{
    public class HttpApiTests
    {
        Lifenizer lifenizer ;
        [SetUp]
        public void Setup()
        {
            var importer = new Mock<IImporter>();
            importer.Setup(i=>i.Import("a")).Returns("b");
            var storer = new Mock<IStorage>();
            storer.Setup(i=>i.SaveFile("b",It.IsAny<Conversation>())).Returns("c");
            var indexer = new Mock<ISearcher>();
            indexer.Setup(i=>i.IndexSingle(It.IsAny<Conversation>()));
            lifenizer = new Lifenizer(importer.Object,indexer.Object,storer.Object);
        }

        [Test]
        public void Index()
        {
            var converterFactory = new Mock<ConverterFactory>();
            converterFactory.Setup(cf=>cf.ConvertFile(It.IsAny<string>(),It.IsAny<string>()))
            .Returns(new Conversation());
            var importer = new Mock<IImporter>();
            importer.Setup(i=>i.Import("a")).Returns("b");
            var storer = new Mock<IStorage>();
            storer.Setup(i=>i.SaveFile("b",It.IsAny<Conversation>())).Returns("c");
            var indexer = new Mock<ISearcher>();
            indexer.Setup(i=>i.IndexSingle(It.IsAny<Conversation>()));
            lifenizer = new Lifenizer(importer.Object,indexer.Object,storer.Object);
            ConverterFactory.Instance = converterFactory.Object;


            lifenizer.Import("a");

            importer.Verify(i=>i.Import("a"),Times.Once);
            storer.Verify(i=>i.SaveFile("b",It.IsAny<Conversation>()),Times.Once);
            indexer.Verify(i=>i.IndexSingle(It.IsAny<Conversation>()),Times.Once);
        }
        
        [Test]
        public void SearchSimple()
        {
            var match = new lifenizer.Search.Match(new Conversation(),new DataPoint("hi"));
            var indexer = new Mock<ISearcher>();
            indexer.Setup(i=>i.FindMatches("query",2)).Returns(new lifenizer.Search.Match[]{match});
            lifenizer = new Lifenizer(null,indexer.Object,null);

            var result = lifenizer.Search("query",2);

            Assert.AreEqual(match,result.First());
            indexer.Verify(i=>i.FindMatches("query",2),Times.Once);
        }

        [Test]
        public void GetFile()
        {
            var storage = new Mock<IStorage>();
            var fs = (new Mock<Stream>()).Object;
            storage.Setup(i=>i.GetFile("url")).Returns(fs);
            lifenizer = new Lifenizer(null,null,storage.Object);

            var stream = lifenizer.GetFile("url");

            Assert.AreEqual(fs,stream);
        }
    }
}