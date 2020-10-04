using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using lifenizer.DataModels;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging;

namespace lifenizer.Api.Controllers
{
    [ApiController]
    [Route ("[controller]")]
    public class ImportController : ControllerBase
    {
        private readonly ILogger<ImportController> _logger;

        public ImportController (ILogger<ImportController> logger)
        {
            _logger = logger;
        }

        [HttpGet]
        public IEnumerable<Conversation> Get ()
        {
            var rng = new Random ();
            Console.WriteLine ("hit request with file ");
            return Enumerable.Range (1, 5).Select (index => new Conversation
                {
                    DataPoints = new List<DataPoint> () { new DataPoint ("nice") }
                })
                .ToArray ();
        }

        [HttpPost]
        public async Task<IActionResult> Index ([FromBody] IFormFile formFile)
        {
            long size = formFile.Length;
            Console.WriteLine ("hit endpoint with file " + size);

            var filePaths = new List<string> ();
            if (formFile.Length > 0)
            {
                // full path to file in temp location
                var filePath = Path.GetTempFileName (); //we are using Temp file name just for the example. Add your own file path.
                filePaths.Add (filePath);
                using (var stream = new FileStream (filePath, FileMode.Create))
                {
                    await formFile.CopyToAsync (stream);
                }
            }

            // process uploaded files
            // Don't rely on or trust the FileName property without validation.
            return Ok (new { size, filePaths });
        }
    }
}
