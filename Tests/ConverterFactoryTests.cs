using lifenizer.Converters;
using Moq;
using NUnit.Framework;

namespace Tests
{
    public class ConverterFactoryTests
    {
        string path = "/a/b/path.test";
        [Test]
        public void AddAndRetrieve()
        {
            var conMock = new Mock<IConverter>();
            conMock.Setup(con=>con.MimeTypes).Returns(new string[]{"test"});
            var factory = new ConverterFactory();
            

            factory.AddConverter(conMock.Object);
            factory.ConvertFile(path);

            conMock.Verify(con=>con.MimeTypes,Times.Once);
            conMock.Verify(con=>con.Convert(path),Times.Once);
        }

        /// <summary>
        /// Tries to call a not registered converter
        /// </summary>
        [Test]
        public void NotRegisteredConverter()
        {
            var converterId = "chat/minecraft";
            var factory = new ConverterFactory();
            Assert.Throws<System.Exception>(()=>factory.ConvertFile(path),$"No Converter found for the passed identifier '{converterId}' or fileextetnion '{System.IO.Path.GetExtension(path)}'");
        }
    }

}