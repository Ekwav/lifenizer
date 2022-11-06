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

        public SearchController(Lifenizer lifenizer)
        {
            ConverterFactory.Instance.LoadFromAssemblies();
            this.lifenizer = lifenizer;
        }

        [Microsoft.AspNetCore.Authorization.Authorize]
        [HttpGet("{value?}"), DisableRequestSizeLimit]
        public IActionResult Search(string value = null,[FromQuery] int page = 1)
        {
            var matches = lifenizer.Search(value,1);
            var matcheList = matches.ToList();

            var result = new Pagination<Conversation>(page,10);
            result.Build(matcheList.AsQueryable());

            return Ok(result);
        }
    }
}