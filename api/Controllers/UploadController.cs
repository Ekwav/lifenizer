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
    public class UploadController : ControllerBase
    {
        private Lifenizer lifenizer;

        public UploadController()
        {
            ConverterFactory.Instance.LoadFromAssemblies();
            Console.WriteLine(SimplerConfig.Config.Instance["storagePath"]);
            lifenizer = new Lifenizer(
                new lifenizer.Importers.FileSystemImporter(), 
                new lifenizer.Search.LucenceSearch(SimplerConfig.Config.Instance["indexPath"]), 
                new lifenizer.Storage.LocalFileStorage(SimplerConfig.Config.Instance["storagePath"]));
        }

        [HttpPost("{converter?}"), DisableRequestSizeLimit]
        public IActionResult Upload(string converter = null)
        {
            try
            {
                Console.WriteLine(converter);
                var file = Request.Form.Files[0];
                Console.WriteLine(Request.Headers["Authorization"]);
                var tempPath =  Path.Combine(Path.GetTempPath(),"Resources", "Images");
                Directory.CreateDirectory(tempPath);

                if (file.Length > 0)
                {
                    var fileName = file.FileName.Trim();
                    var fullPath = Path.Combine(tempPath, fileName);
                    Console.WriteLine(fullPath);
                    using(var stream = new FileStream(fullPath, FileMode.Create))
                    {
                        file.CopyTo(stream);
                    }
                    
                    // start the importer
                    lifenizer.Import(fullPath,converter);

                    return Ok(new { tempPath });
                }
                else
                {
                    return BadRequest();
                }
            }
            catch (Exception ex)
            {
                return StatusCode(500, $"Internal server error: {ex}");
            }
        }
    }
}