using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Threading.Tasks;
using lifenizer;
using Microsoft.AspNetCore.Http;
using lifenizer.DataModels;
using lifenizer.Converters;
using Messaia.Net.Pagination;
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

        [Microsoft.AspNetCore.Authorization.Authorize]
        [HttpGet("{value?}"), DisableRequestSizeLimit]
        public IActionResult Upload(string value = null,[FromQuery] int page = 1)
        {
            Console.WriteLine("hi"+value);
            var matches = lifenizer.Search(value,1);
            var matcheList = matches.ToList();
            matcheList.AddRange(matches);
            matcheList.AddRange(matcheList);
            matcheList.AddRange(matcheList);
            matcheList.AddRange(matcheList);
            matcheList.AddRange(matcheList);

            var result = new Pagination<Conversation>(page,10);
            result.Build(matcheList.AsQueryable());

            return Ok(result);
        }
    }
}