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
using Microsoft.Extensions.Logging.Abstractions;

namespace lifenizer.Api.Controllers
{

    [Route("api/[controller]")]
    [ApiController]
    public class StorageController : ControllerBase
    {
        private Lifenizer lifenizer;

        public StorageController()
        {
            lifenizer = new Lifenizer(
                new lifenizer.Importers.FileSystemImporter(), 
                new lifenizer.Search.LucenceSearch(SimplerConfig.Config.Instance["indexPath"], NullLogger<Search.LucenceSearch>.Instance), 
                new lifenizer.Storage.LocalFileStorage(SimplerConfig.Config.Instance["storagePath"]));
        }

        [Microsoft.AspNetCore.Authorization.Authorize]
        [HttpGet("{uuid?}")]
        public IActionResult GetFile(string uuid = null)
        {
            return File(lifenizer.GetFile(uuid.Split('.').First()),MimeTypes.MimeTypeMap.GetMimeType(uuid),null,true);
        }
    }
}