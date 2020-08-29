using System;
using System.IO;

namespace lifenizer.Importers
{
    /// <summary>
    /// Imports files from the same filesystem by simply copying them to /tmp
    /// </summary>
    public class FileSystemImporter : IImporter
    {
        public string Import(string localPath)
        {
            var tempPath = Path.Combine(Path.GetTempPath(),"lifenizer","intermediate",DateTime.Now.Ticks.ToString());
            Directory.CreateDirectory(tempPath);
            var fileName = Path.Combine(tempPath, Lifenizer.SOURCE_FILE_NAME);
            File.Copy(localPath,fileName);
            return fileName;
        }
    }

    public interface IImporter
    {
        /// <summary>
        /// Imports a file given arguments
        /// </summary>
        /// <param name="arguments"></param>
        /// <returns>The path to the imported file</returns>
        string Import(string arguments);
    }
}