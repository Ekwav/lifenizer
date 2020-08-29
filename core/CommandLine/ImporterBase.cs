using System;
using System.IO;
using ManyConsole;

namespace lifenizer
{
    /// <summary>
    /// Imports data from some source, generates .ls Files and puts them into the <see cref="IndexDir"/>
    /// </summary>
    public abstract class ImporterBase : ConsoleCommand
    {
        public string IndexDir 
        {
            get {
                return Path.Combine(Program.DefaultDataPath,"indexes",ProductName);
            }
        }

        public string TempDir
        {
            get 
            {
                return Path.Combine(Program.DefaultDataPath,"temp",ProductName);
            }
        }

        public abstract string ProductName {get;}

        public void MoveTempFileToIndex(string fileName,string newName = null)
        {
            if(newName == null)
                newName = fileName;
            var folderName = DateTime.Now.ToString("yyyy-MM-dd-hh-mm-ss");
            var indexLocation = Path.Combine(IndexDir,folderName);
            Directory.CreateDirectory(indexLocation);
            var temporaryFolder = Path.Combine(Program.DefaultDataPath,"temp");
            File.Copy(Path.Combine(temporaryFolder,fileName),Path.Combine(indexLocation,newName));
        }


    }
}