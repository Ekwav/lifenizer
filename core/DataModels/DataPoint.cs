namespace lifenizer.DataModels
{
    /// <summary>
    /// Represents single pice of information, equivelent of a sentence of a conversation
    /// </summary>
    public class DataPoint
    {
        public DataPoint(string content,int offset = 0)
        {
            Offset = offset;
            Content = content;
        }

        /// <summary>
        /// Offset of this Datapoint to the start, either seconds or characters.
        /// Not Lines, count the characters
        /// </summary>
        /// <value></value>
        public int Offset {get;set;}

        /// <summary>
        /// Content of the datapoint, either single word, sentence, message or line
        /// </summary>
        /// <value></value>
        public string Content {get;set;}
    }

}