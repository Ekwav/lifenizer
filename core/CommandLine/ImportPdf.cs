using System;
using System.Diagnostics;
using System.IO;

namespace lifenizer
{
    public class ImportPdf : ImporterBase
    {
        private string FileLocation;

        private bool IsPdf;

        public ImportPdf () {
            // Register the actual command with a simple (optional) description.
            IsCommand ("import", "Quick import data.");

            // Add a longer description for the help on that specific command.
            HasLongDescription ("Imports some data to be searchable " +
                "\n uses tesseract to do so");

            // Required options/flags, append '=' to obtain the required value.
            HasRequiredOption ("f|file=", "The full path of the file.", p => FileLocation = p);

            // Optional options/flags, append ':' to obtain an optional value, or null if not specified.
            HasOption ("p|pdf:", "pdf.",
                t => IsPdf = t == null ? true : Convert.ToBoolean (t));
        }

        public override string ProductName => "pdf";

        public override int Run(string[] remainingArguments)
        {
            var inputTempFile = Path.Combine(TempDir,"input.pdf");
            var ouputTempFile = Path.Combine(TempDir,"output.pdf");
            var ouputTempText = Path.Combine(TempDir,"text.txt");

            Directory.CreateDirectory(TempDir);
            File.Delete(inputTempFile);
            File.Copy(FileLocation,inputTempFile);

            var command = $" run --rm -v {TempDir}:/data ocrpdf -l deu --rotate-pages --sidecar /data/text.txt /data/input.pdf /data/output.pdf";

            ProcessHandler.Instance
                .RunCommandline("docker",command)
                .WaitForExit();

            // move output 
            var fileName = Path.GetFileNameWithoutExtension(FileLocation);
            MoveTempFileToIndex("input.pdf",$"{fileName}.pdf");
            MoveTempFileToIndex($"{fileName}.ls");

            return 0;
        }
    }
}