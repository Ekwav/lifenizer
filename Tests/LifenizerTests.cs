using System.IO;
using System.Linq;
using lifenizer;
using lifenizer.Converters;
using lifenizer.DataModels;
using lifenizer.Importers;
using lifenizer.Search;
using lifenizer.Storage;
using Moq;
using NUnit.Framework;

namespace Tests
{
    public class HttpApiTests
    {
        private const string IMPORT_FILE_NAME = "a";
        private const string IMPORTER_NAME = "chat";
        readonly Conversation CONVERSATION = new Conversation();
        Lifenizer lifenizer;
        Mock<IImporter> importer;
        Mock<IStorage> storer;
        Mock<ISearcher> indexer;
        [SetUp]
        public void Setup()
        {
            importer = new Mock<IImporter>();
            importer.Setup(i => i.Import(IMPORT_FILE_NAME)).Returns("b");
            storer = new Mock<IStorage>();
            storer.Setup(i => i.SaveFile("b", It.IsAny<Conversation>())).Returns("c");
            indexer = new Mock<ISearcher>();
            indexer.Setup(i => i.IndexSingle(It.IsAny<Conversation>()));
            lifenizer = new Lifenizer(importer.Object, indexer.Object, storer.Object);
        }

        [Test]
        public void ImportGuess()
        {
            var converterFactory = new Mock<IConverterFactory>();
            converterFactory.Setup(cf => cf.ConvertFile(It.IsAny<string>(), null))
                .Returns(CONVERSATION);
            ConverterFactory.Instance = converterFactory.Object;

            lifenizer.Import(IMPORT_FILE_NAME);

            converterFactory.Verify(c => c.ConvertFile(It.IsAny<string>(), null), Times.Once);

            importer.Verify(i => i.Import(IMPORT_FILE_NAME), Times.Once);
            storer.Verify(i => i.SaveFile("b", CONVERSATION), Times.Once);
            indexer.Verify(i => i.IndexSingle(CONVERSATION), Times.Once);
        }

        [Test]
        public void ImportConverterProvided()
        {
            var converterFactory = new Mock<ConverterFactory>();
            converterFactory.Setup(cf => cf.ConvertFile(It.IsAny<string>(), IMPORTER_NAME))
                .Returns(CONVERSATION);
            ConverterFactory.Instance = converterFactory.Object;

            lifenizer.Import(IMPORT_FILE_NAME, IMPORTER_NAME);

            converterFactory.Verify(c => c.ConvertFile(It.IsAny<string>(), IMPORTER_NAME), Times.Once);

            importer.Verify(i => i.Import(IMPORT_FILE_NAME), Times.Once);
            storer.Verify(i => i.SaveFile("b", CONVERSATION), Times.Once);
            indexer.Verify(i => i.IndexSingle(CONVERSATION), Times.Once);
        }

        [Test]
        public void SearchSimple()
        {
            var match = new lifenizer.Search.Match(new Conversation(), new DataPoint("hi"));
            var indexer = new Mock<ISearcher>();
            indexer.Setup(i => i.FindMatches("query", 2)).Returns(new lifenizer.Search.Match[] { match });
            lifenizer = new Lifenizer(null, indexer.Object, null);

            var result = lifenizer.Search("query", 2);

            Assert.AreEqual(match, result.First());
            indexer.Verify(i => i.FindMatches("query", 2), Times.Once);
        }

        [Test]
        public void GetFile()
        {
            var storage = new Mock<IStorage>();
            var fs = (new Mock<Stream>()).Object;
            storage.Setup(i => i.GetFile("url")).Returns(fs);
            lifenizer = new Lifenizer(null, null, storage.Object);

            var stream = lifenizer.GetFile("url");

            Assert.AreEqual(fs, stream);
        }
    }
}