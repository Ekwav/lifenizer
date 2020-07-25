using System.IO;
using lifenizer.DataModels;

namespace lifenizer.Converters
{
    public class ImageOcrConverter : IConverter
    {
        public Conversation Convert(string path, params string[] options)
        {
            var hostDirectory = Path.GetDirectoryName(path);
            var command = $" run --rm -v {hostDirectory}:/data tesseractshadow/tesseract4re tesseract /data/{Path.GetFileName(path)} /data/result -l deu";

            ProcessHandler.Instance
                .RunCommandline("docker",command)
                .WaitForExit();

            var offset = 0;
            var conversation = new Conversation();
            foreach (var item in File.ReadLines(Path.Combine(hostDirectory,"result.txt")))
            {
                conversation.DataPoints.Add(new DataPoint(item,offset));
                offset += item.Length +1;
            } 
            return conversation;
        }
    }


    public interface IConverter
    {
        /// <summary>
        /// Converts a file under a given path to a <see cref="Conversation"/>
        /// </summary>
        /// <param name="path">The path of the file to import</param>
        /// <returns>A <see cref="Conversation"/> with the relevant content of the file to import</returns>
        Conversation Convert(string path, params string[] options);
    }
}

