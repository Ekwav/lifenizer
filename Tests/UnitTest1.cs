using System;
using lifenizer;
using NUnit.Framework;

namespace Tests
{
    public class Tests
    {
        [SetUp]
        public void Setup()
        {
        }

        [Test]
        public void Test1()
        {
            Console.WriteLine("okay");
            Assert.Pass();
        }

    }

    public class PdfImportTests
    {
        [Test]
        public void ImportPdf()
        {
            
        }
    }

    public class ControllerTests
    {
        [Test]
        public void CreateLifenizer()
        {
            var liefenizer = new Lifenizer();
        }
    }
}