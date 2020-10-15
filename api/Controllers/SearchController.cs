using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using lifenizer;
using Microsoft.AspNetCore.Http;
using lifenizer.Converters;
using Microsoft.AspNetCore.Mvc;

namespace lifenizer.Api.Controllers
{

    [Route("api/[controller]")]
    [ApiController]
    public class SearchController : ControllerBase
    {
        private Lifenizer lifenizer;

        public SearchController()
        {
            Console.WriteLine("created");
            ConverterFactory.Instance.LoadFromAssemblies();
            Console.WriteLine(SimplerConfig.Config.Instance["storagePath"]);
            lifenizer = new Lifenizer(
                new lifenizer.Importers.FileSystemImporter(), 
                new lifenizer.Search.LucenceSearch(SimplerConfig.Config.Instance["indexPath"]), 
                new lifenizer.Storage.LocalFileStorage(SimplerConfig.Config.Instance["storagePath"]));
        }

        [HttpGet("{value?}"), DisableRequestSizeLimit]
        public IActionResult Upload(string value = null)
        {
            Console.WriteLine("hi"+value);
            var matches = lifenizer.Search(value,1);

            return Ok(new { matches });
        }
    }
}