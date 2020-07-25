namespace lifenizer.Importers
{
    /// <summary>
    /// Imports files from the same filesystem by simply copying them
    /// </summary>
    public class FileSystemImporter : IImporter
    {
        public string Import(string arguments)
        {
            throw new System.NotImplementedException();
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