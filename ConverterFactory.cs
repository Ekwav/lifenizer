using lifenizer.DataModels;

namespace lifenizer
{
    public class ConverterFactory
    {
        public static ConverterFactory Instance {get;set;}

        static ConverterFactory()
        {
            Instance = new ConverterFactory();
        }

        public Conversation ConvertFile(string tempPath)
        {
            return new Conversation();
        }
    }

}